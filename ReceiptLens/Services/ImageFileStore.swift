import Foundation
import UIKit

final class ImageFileStore: @unchecked Sendable {
    private let directory: URL
    private let maxDimension: CGFloat = 1600
    private let jpegQuality: CGFloat = 0.92

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Resize, encode, and save an image off the main thread. Returns the
    /// absolute URL of the written JPEG.
    func saveForAnalysis(_ image: UIImage) async throws -> URL {
        let filename = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(filename)
        let maxDim = maxDimension
        let quality = jpegQuality

        try await Task.detached(priority: .userInitiated) {
            let scaled = image.resizedForVision(maxDimension: maxDim)
            guard let data = scaled.jpegData(compressionQuality: quality) else {
                throw ImageStoreError.encodingFailed
            }
            try data.write(to: url, options: [.atomic])
        }.value

        return url
    }

    func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Delete the scan image with the given filename. Safe to call from any task.
    func delete(filename: String) async throws {
        let url = directory.appendingPathComponent(filename)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }.value
    }

    /// Remove any images on disk not referenced by the given filename set.
    func pruneOrphans(referencedFilenames: Set<String>) async {
        let directory = self.directory
        await Task.detached(priority: .utility) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                return
            }
            for url in contents where !referencedFilenames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }

    /// Load and decode a scan image off the main thread.
    func loadImage(at url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}

enum ImageStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "Could not encode image."
    }
}

private extension UIImage {
    func resizedForVision(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
