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

    private let wrapper = MTMDWrapper()
    private var cancellables = Set<AnyCancellable>()
    private var loadedPaths: (String, String)?

    init() {
        wrapper.$fullOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.output = text
            }
            .store(in: &cancellables)
    }

    func analyze(imageURL: URL, prompt: String, files: ModelFiles) async throws -> String {
        guard files.isReady else {
            throw MiniCPMEngineError.modelsMissing
        }

        try await loadIfNeeded(files: files)
        state = .running
        output = ""

        wrapper.clearKVCacheForNewTurn()
        try await wrapper.addImageInBackground(imageURL.path)
        try await wrapper.addTextInBackground(prompt, role: "user")
        try await wrapper.startGeneration()

        while wrapper.generationState == .generating {
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        if case .failed(let error) = wrapper.generationState {
            state = .failed(error.localizedDescription)
            throw error
        }

        state = .ready
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fail(_ message: String) {
        state = .failed(message)
    }

    private func loadIfNeeded(files: ModelFiles) async throws {
        let paths = (files.llm.path, files.mmproj.path)
        if loadedPaths?.0 == paths.0, loadedPaths?.1 == paths.1, wrapper.initializationState == .initialized {
            return
        }

        if wrapper.initializationState == .initialized {
            await wrapper.reset()
        }

        state = .loading
        let params = MTMDParams(
            modelPath: paths.0,
            mmprojPath: paths.1,
            nPredict: 768,
            nCtx: 4096,
            nThreads: 4,
            temperature: 0.2,
            useGPU: true,
            mmprojUseGPU: true,
            warmup: true,
            nUbatch: 256,
            imageMaxSliceNums: -1,
            imageMaxTokens: 256
        )
        try await wrapper.initialize(with: params)
        loadedPaths = paths
        state = .ready
    }
}

enum MiniCPMEngineError: LocalizedError {
    case modelsMissing

    var errorDescription: String? {
        "Download the model files first."
    }
}

