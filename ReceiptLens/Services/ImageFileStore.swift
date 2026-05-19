import Foundation
import UIKit

final class ImageFileStore {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func saveForAnalysis(_ image: UIImage) throws -> URL {
        let scaled = image.resizedForVision(maxDimension: 1600)
        guard let data = scaled.jpegData(compressionQuality: 0.92) else {
            throw ImageStoreError.encodingFailed
        }

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try data.write(to: url, options: [.atomic])
        return url
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

