import Foundation
import Combine
import llama

@MainActor
public final class MTMDWrapper: ObservableObject {
    @Published public private(set) var fullOutput: String = ""
    @Published public private(set) var generationState: MTMDGenerationState = .idle
    @Published public private(set) var initializationState: MTMDInitializationState = .notInitialized
    @Published public private(set) var hasContent: Bool = false

    private var context: OpaquePointer?
    private var generationTask: Task<Void, Never>?
    private let bridgeQueue = DispatchQueue(label: "mb_mtmd.bridge", qos: .userInitiated)

    public static let defaultPrefillTimeoutSeconds: TimeInterval = 180

    public init() {}

    // No deinit: the app holds a single MTMDWrapper for its full lifetime via
    // AppState/MiniCPMEngine. Tearing down is handled via explicit `reset()`,
    // which can await in-flight C work before freeing. Doing the same from
    // deinit would either violate main-actor isolation or skip the await.

    public func initialize(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }

        initializationState = .initializing

        let ctx: OpaquePointer? = await withCheckedContinuation { continuation in
            bridgeQueue.async {
                var cParams = params.toCParams()
                let result = params.modelPath.withCString { modelCStr in
                    params.mmprojPath.withCString { mmprojCStr in
                        mb_mtmd_init(modelCStr, mmprojCStr, &cParams)
                    }
                }
                continuation.resume(returning: result)
            }
        }

        guard let ctx else {
            let detail = mb_mtmd_get_last_init_error().map { String(cString: $0) } ?? ""
            let message = detail.isEmpty ? "Failed to create MTMD context" : detail
            let err = MTMDError.initializationFailed(message)
            initializationState = .failed(err)
            throw err
        }

        context = ctx
        initializationState = .initialized
    }

    /// Prefill one MiniCPM-V 4.6 user turn containing an image and a text
    /// prompt, both inside the same chatml user role. Matches how the model
    /// was trained.
    public func addUserImageAndText(
        imagePath: String,
        text: String,
        timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds
    ) async throws {
        try await prefill(label: "addUserImageAndText", timeoutSeconds: timeoutSeconds, errorFactory: MTMDError.imageLoadFailed) { ctx in
            imagePath.withCString { imageCStr in
                text.withCString { textCStr in
                    mb_mtmd_prefill_user_image_text(ctx, imageCStr, textCStr)
                }
            }
        }
    }

    public func addText(_ text: String, role: String = "user") async throws {
        try await prefill(label: "addText", timeoutSeconds: MTMDWrapper.defaultPrefillTimeoutSeconds, errorFactory: MTMDError.textAddFailed) { ctx in
            text.withCString { textCStr in
                role.withCString { roleCStr in
                    mb_mtmd_prefill_text(ctx, textCStr, roleCStr)
                }
            }
        }
    }

    private func prefill(
        label: String,
        timeoutSeconds: TimeInterval,
        errorFactory: @escaping @Sendable (String) -> MTMDError,
        body: @escaping @Sendable (OpaquePointer) -> Int32
    ) async throws {
        guard initializationState == .initialized, let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await withTimeout(seconds: timeoutSeconds, label: label) { [bridgeQueue] in
            try await withCheckedThrowingContinuation { continuation in
                bridgeQueue.async {
                    let result = body(ctx)
                    if result != 0 {
                        let msg = mb_mtmd_get_last_error(ctx).map { String(cString: $0) } ?? "Unknown error"
                        continuation.resume(throwing: errorFactory(msg))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        hasContent = true
    }

    /// Run a full generation pass. Streams tokens into `fullOutput` as they arrive
    /// and returns the trimmed final output when generation completes naturally.
    /// Throws `CancellationError` if cancelled, or the underlying `MTMDError` on
    /// failure inside the C call.
    public func runGeneration() async throws -> String {
        guard initializationState == .initialized, let ctx = context else {
            throw MTMDError.contextNotInitialized
        }
        guard hasContent else {
            throw MTMDError.noContentToGenerate
        }
        guard generationState != .generating else {
            throw MTMDError.generationInProgress
        }

        // Drain any prior generation task before starting a new one.
        if let prior = generationTask {
            prior.cancel()
            await prior.value
        }

        generationState = .generating
        fullOutput = ""

        let task = Task { [weak self] in
            guard let self else { return }
            await self.driveGeneration(ctx: ctx)
        }
        generationTask = task

        // Propagate outer cancellation into the generation task.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        switch generationState {
        case .completed:
            return fullOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cancelled:
            throw CancellationError()
        case .failed(let error):
            throw error
        default:
            return fullOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func stopGeneration() {
        generationTask?.cancel()
        // Don't set state here; the generation task will set .cancelled itself
        // once it observes the cancellation between token iterations.
    }

    private func driveGeneration(ctx: OpaquePointer) async {
        while !Task.isCancelled {
            let cToken: mb_mtmd_token = await withCheckedContinuation { continuation in
                bridgeQueue.async {
                    continuation.resume(returning: mb_mtmd_loop(ctx))
                }
            }

            var piece = cToken.token != nil ? String(cString: cToken.token!) : ""
            if let tokenPtr = cToken.token {
                mb_mtmd_string_free(tokenPtr)
            }

            // Swallow leading newline from the assistant header to keep output clean.
            if fullOutput.isEmpty && piece == "\n" {
                piece = ""
            }
            fullOutput += piece

            if cToken.is_end {
                generationState = .completed
                return
            }
        }
        generationState = .cancelled
    }

    /// Wipe the KV cache for sequence 0 and reset n_past. Use between turns to
    /// start a fresh prefill without tearing down the model.
    public func clearKVCacheForNewTurn() async {
        guard let ctx = context else { return }
        await withCheckedContinuation { continuation in
            bridgeQueue.async {
                _ = mb_mtmd_clean_kv_cache(ctx)
                continuation.resume()
            }
        }
        hasContent = false
    }

    /// Tear down the C context. Waits for any in-flight bridge work to finish
    /// before freeing, so this is safe to call mid-generation.
    public func reset() async {
        if let task = generationTask {
            task.cancel()
            await task.value
        }
        generationTask = nil

        // Drain the bridge queue so no C call is in flight when we free.
        await withCheckedContinuation { continuation in
            bridgeQueue.async {
                continuation.resume()
            }
        }

        if let ctx = context {
            mb_mtmd_free(ctx)
            context = nil
        }

        initializationState = .notInitialized
        generationState = .idle
        fullOutput = ""
        hasContent = false
    }

    private func withTimeout(
        seconds: TimeInterval,
        label: String,
        body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MTMDError.timeout("\(label) timed out after \(Int(seconds))s")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
