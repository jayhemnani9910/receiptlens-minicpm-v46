import Foundation
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published var scans: [ReceiptScan] = []

    let modelStore = ModelStore()
    let engine = MiniCPMEngine()
    let imageStore = ImageFileStore()

    func analyze(image: UIImage, mode: AnalysisMode, customPrompt: String) async {
        do {
            let imageURL = try imageStore.saveForAnalysis(image)
            let prompt = PromptTemplate.prompt(for: mode, customPrompt: customPrompt)
            let text = try await engine.analyze(
                imageURL: imageURL,
                prompt: prompt,
                files: modelStore.files
            )
            scans.insert(
                ReceiptScan(
                    mode: mode,
                    imageURL: imageURL,
                    prompt: prompt,
                    output: text,
                    createdAt: Date()
                ),
                at: 0
            )
        } catch {
            engine.fail("Analysis failed: \(error.localizedDescription)")
        }
    }
}

