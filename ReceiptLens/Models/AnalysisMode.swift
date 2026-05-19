import Foundation

enum AnalysisMode: String, CaseIterable, Identifiable, Codable {
    case receipt = "Receipt"
    case document = "Document"
    case screen = "Screen"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .receipt: "receipt"
        case .document: "doc.text.viewfinder"
        case .screen: "rectangle.and.text.magnifyingglass"
        }
    }
}

