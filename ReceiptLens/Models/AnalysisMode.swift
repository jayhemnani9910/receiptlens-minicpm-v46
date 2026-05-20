import SwiftUI

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

    /// Subtle per-mode glyph tint for History rows and the Detail pill.
    /// Chip *selection* still uses the single app accent.
    var tint: Color {
        switch self {
        case .receipt: .teal
        case .document: .indigo
        case .screen: .orange
        }
    }

    var label: String { rawValue }
}
