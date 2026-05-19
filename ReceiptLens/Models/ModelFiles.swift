import Foundation

struct ModelFiles {
    let directory: URL
    let llm: URL
    let mmproj: URL

    var isReady: Bool {
        FileManager.default.fileExists(atPath: llm.path)
            && FileManager.default.fileExists(atPath: mmproj.path)
    }
}

enum ModelAsset: CaseIterable, Identifiable {
    case llm
    case mmproj

    var id: String { fileName }

    var displayName: String {
        switch self {
        case .llm: "MiniCPM-V 4.6 LLM"
        case .mmproj: "Vision projector"
        }
    }

    var fileName: String {
        switch self {
        case .llm: "MiniCPM-V-4_6-Q4_K_M.gguf"
        case .mmproj: "MiniCPM-V-4_6-mmproj-master-f16.gguf"
        }
    }

    var remoteFileName: String {
        switch self {
        case .llm: "MiniCPM-V-4_6-Q4_K_M.gguf"
        case .mmproj: "mmproj-model-f16.gguf"
        }
    }

    var url: URL {
        URL(string: "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main/\(remoteFileName)")!
    }
}

