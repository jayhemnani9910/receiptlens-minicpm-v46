import Combine
import Foundation

@MainActor
final class MiniCPMEngine: ObservableObject {
    enum EngineState: Equatable {
        case idle
        case loading
        case ready
        case running
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Idle"
            case .loading: "Loading model"
            case .ready: "Ready"
            case .running: "Reading"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var output = ""

    let wrapper = MTMDWrapper()
    private var cancellables = Set<AnyCancellable>()
    private var loadedPaths: (String, String)?

    init() {
        // wrapper is @MainActor, so $fullOutput already publishes on main.
        // No DispatchQueue.main hop needed.
        wrapper.$fullOutput
            .sink { [weak self] text in
                self?.output = text
            }
            .store(in: &cancellables)
    }

    func analyze(imageURL: URL, prompt: String, files: ModelFiles) async throws -> String {
        guard state != .running, state != .loading else {
            throw MiniCPMEngineError.busy
        }
        guard files.isReady else {
            throw MiniCPMEngineError.modelsMissing
        }

        try await loadIfNeeded(files: files)
        state = .running
        output = ""

        do {
            await wrapper.clearKVCacheForNewTurn()
            try await wrapper.addUserImageAndText(imagePath: imageURL.path, text: prompt)
            let result = try await wrapper.runGeneration()
            state = .ready
            return result
        } catch is CancellationError {
            // User tapped Stop. Keep whatever streamed so far; this is not a failure.
            state = .ready
            return output
        } catch {
            state = .failed("Analysis failed: \(error.localizedDescription)")
            throw error
        }
    }

    func stop() {
        wrapper.stopGeneration()
    }

    func fail(_ message: String) {
        state = .failed(message)
    }

    private func loadIfNeeded(files: ModelFiles) async throws {
        let paths = (files.llm.path, files.mmproj.path)
        if loadedPaths?.0 == paths.0,
           loadedPaths?.1 == paths.1,
           wrapper.initializationState == .initialized {
            return
        }

        if wrapper.initializationState == .initialized {
            await wrapper.reset()
        }

        state = .loading
        let params = MTMDParams(
            modelPath: paths.0,
            mmprojPath: paths.1,
            nPredict: EngineConfig.nPredict,
            nCtx: EngineConfig.nCtx,
            nThreads: EngineConfig.nThreads,
            temperature: EngineConfig.temperature,
            useGPU: true,
            mmprojUseGPU: true,
            warmup: true,
            nUbatch: EngineConfig.nUbatch,
            imageMaxSliceNums: EngineConfig.imageMaxSliceNums,
            imageMaxTokens: EngineConfig.imageMaxTokens
        )
        do {
            try await wrapper.initialize(with: params)
        } catch {
            state = .failed("Load failed: \(error.localizedDescription)")
            throw error
        }
        loadedPaths = paths
        state = .ready
    }
}

enum MiniCPMEngineError: LocalizedError {
    case modelsMissing
    case busy

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            return "Download the model files first."
        case .busy:
            return "Engine is already busy."
        }
    }
}
