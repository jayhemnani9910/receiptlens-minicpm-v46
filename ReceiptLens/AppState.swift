import Combine
import Foundation
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published var scans: [ReceiptScan] = []

    let modelStore = ModelStore()
    let engine = MiniCPMEngine()
    let imageStore = ImageFileStore()

    private var cancellables = Set<AnyCancellable>()
    private let scansURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scansURL = documents.appendingPathComponent("scans.json")

        scans = Self.loadScans(from: scansURL)

        // Re-publish nested ObservableObject changes so views observing AppState
        // see updates from engine / modelStore. Without this, token streaming and
        // download progress don't drive UI updates.
        engine.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Persist scans whenever the list changes.
        $scans
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] scans in
                self?.persistScans(scans)
            }
            .store(in: &cancellables)

        // Reconcile scan images on disk with the persisted scan list.
        Task { [imageStore, scans] in
            await imageStore.pruneOrphans(referencedFilenames: Set(scans.map(\.imageFilename)))
        }
    }

    func analyze(image: UIImage, mode: AnalysisMode, customPrompt: String) async {
        do {
            let imageURL = try await imageStore.saveForAnalysis(image)
            let prompt = PromptTemplate.prompt(for: mode, customPrompt: customPrompt)
            let text = try await engine.analyze(
                imageURL: imageURL,
                prompt: prompt,
                files: modelStore.files
            )
            scans.insert(
                ReceiptScan(
                    mode: mode,
                    imageFilename: imageURL.lastPathComponent,
                    prompt: prompt,
                    output: text
                ),
                at: 0
            )
        } catch {
            engine.fail("Analysis failed: \(error.localizedDescription)")
        }
    }

    func deleteScans(at offsets: IndexSet) {
        let removed = offsets.map { scans[$0] }
        scans.remove(atOffsets: offsets)
        evictAndDelete(removed)
    }

    func deleteScan(_ scan: ReceiptScan) {
        scans.removeAll { $0.id == scan.id }
        evictAndDelete([scan])
    }

    func clearAllScans() {
        let removed = scans
        scans.removeAll()
        evictAndDelete(removed)
    }

    private func evictAndDelete(_ removed: [ReceiptScan]) {
        for scan in removed {
            ThumbnailCache.shared.remove(filename: scan.imageFilename)
        }
        Task { [imageStore] in
            for scan in removed {
                try? await imageStore.delete(filename: scan.imageFilename)
            }
        }
    }

    func imageURL(for scan: ReceiptScan) -> URL {
        imageStore.url(for: scan.imageFilename)
    }

    private func persistScans(_ scans: [ReceiptScan]) {
        let url = scansURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(scans)
                try data.write(to: url, options: [.atomic])
            } catch {
                NSLog("AppState: failed to persist scans: %@", error.localizedDescription)
            }
        }
    }

    private static func loadScans(from url: URL) -> [ReceiptScan] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ReceiptScan].self, from: data)
        } catch {
            NSLog("AppState: failed to load scans: %@", error.localizedDescription)
            return []
        }
    }
}
