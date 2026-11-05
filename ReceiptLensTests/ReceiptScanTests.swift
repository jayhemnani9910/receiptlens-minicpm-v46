import XCTest
@testable import ReceiptLens

final class ReceiptScanTests: XCTestCase {
    func testRoundTripsThroughTheHistoryFileFormat() throws {
        let scan = ReceiptScan(
            mode: .document,
            imageFilename: "A.jpg",
            prompt: "Read this",
            output: "Total: 12.50",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode([ReceiptScan].self, from: encoder.encode([scan]))
        XCTAssertEqual(decoded, [scan])
    }
}

final class ModelAssetTests: XCTestCase {
    func testDownloadURLsPointAtTheOpenBMBRepo() {
        XCTAssertEqual(
            ModelAsset.llm.url.absoluteString,
            "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main/MiniCPM-V-4_6-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            ModelAsset.mmproj.url.absoluteString,
            "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main/mmproj-model-f16.gguf"
        )
    }
}
