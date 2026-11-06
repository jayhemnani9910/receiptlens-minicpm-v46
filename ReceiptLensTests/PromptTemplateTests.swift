import XCTest
@testable import ReceiptLens

final class PromptTemplateTests: XCTestCase {
    func testCustomPromptWinsAndIsTrimmed() {
        let prompt = PromptTemplate.prompt(for: .receipt, customPrompt: "  What is the total?\n")
        XCTAssertEqual(prompt, "What is the total?")
    }

    func testBlankCustomPromptFallsBackToModePrompt() {
        let prompt = PromptTemplate.prompt(for: .receipt, customPrompt: " \n ")
        XCTAssertTrue(prompt.hasPrefix("Extract the receipt"))
    }

    func testEachModeHasItsOwnPrompt() {
        let prompts = AnalysisMode.allCases.map { PromptTemplate.prompt(for: $0, customPrompt: "") }
        XCTAssertEqual(Set(prompts).count, AnalysisMode.allCases.count)
    }
}
