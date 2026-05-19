import Foundation

@MainActor
final class ModelStore: NSObject, ObservableObject {
    enum DownloadState: Equatable {
        case idle
        case downloading(String, Double)
        case ready
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Not downloaded"
            case .downloading(let name, let progress): "\(name) \(Int(progress * 100))%"
            case .ready: "Ready"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: DownloadState = .idle

    let files: ModelFiles

    override init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Models", isDirectory: true)
        files = ModelFiles(
            directory: directory,
            llm: directory.appendingPathComponent(ModelAsset.llm.fileName),
            mmproj: directory.appendingPathComponent(ModelAsset.mmproj.fileName)
        )
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        state = files.isReady ? .ready : .idle
    }

    func downloadAll() async {
        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            for asset in ModelAsset.allCases {
                try await download(asset)
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ asset: ModelAsset) async throws {
        let destination = localURL(for: asset)
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }

        state = .downloading(asset.displayName, 0)

        // Throttle progress updates to once per integer percent — URLSession
        // fires the delegate per chunk (~16 KB), which on a 1 GB GGUF means
        // tens of thousands of callbacks otherwise. The throttle is shared
        // across delegate calls (serial queue, so non-atomic mutation is safe).
        let throttle = ProgressThrottle()
        let displayName = asset.displayName

        let (temporaryURL, response) = try await URLSession.downloadWithProgress(from: asset.url) { [weak self] _, written, total in
            guard total > 0 else { return }
            let percent = Int(Double(written) / Double(total) * 100)
            guard percent != throttle.lastPercent else { return }
            throttle.lastPercent = percent
            let progress = Double(percent) / 100.0
            Task { @MainActor [weak self] in
                self?.state = .downloading(displayName, progress)
            }
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelStoreError.badResponse
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private func localURL(for asset: ModelAsset) -> URL {
        switch asset {
        case .llm: files.llm
        case .mmproj: files.mmproj
        }
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    var lastPercent: Int = -1
}

enum ModelStoreError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        "Model download failed."
    }
}
