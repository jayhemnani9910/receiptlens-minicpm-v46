import Foundation

enum PromptTemplate {
    static func prompt(for mode: AnalysisMode, customPrompt: String) -> String {
        let custom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }

        switch mode {
        case .receipt:
            return """
            Extract the receipt into concise structured text.
            Include merchant, date, line items, quantities, prices, subtotal, tax, tip, discounts, total, payment method, and any mismatch in the math.
            If a field is unclear, write "unclear" instead of guessing.
            """
        case .document:
            return """
            Read this document accurately.
            Return a clean summary, key fields, dates, names, numbers, and any tables you can infer.
            Preserve important wording where exact text matters.
            """
        case .screen:
            return """
            Analyze this screenshot for an agent.
            Describe the visible app/page, actionable controls, important text, current state, and the best next action.
            Avoid guessing hidden content.
            """
        }
    }
}

