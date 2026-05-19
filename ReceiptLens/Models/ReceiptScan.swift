import Foundation

struct ReceiptScan: Identifiable {
    let id = UUID()
    let mode: AnalysisMode
    let imageURL: URL
    let prompt: String
    let output: String
    let createdAt: Date
}

