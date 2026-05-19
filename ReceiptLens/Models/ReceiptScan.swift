import Foundation

struct ReceiptScan: Identifiable, Codable, Equatable {
    let id: UUID
    let mode: AnalysisMode
    let imageFilename: String
    let prompt: String
    let output: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        mode: AnalysisMode,
        imageFilename: String,
        prompt: String,
        output: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.imageFilename = imageFilename
        self.prompt = prompt
        self.output = output
        self.createdAt = createdAt
    }
}
