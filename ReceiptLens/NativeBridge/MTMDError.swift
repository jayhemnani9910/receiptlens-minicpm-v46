import Foundation

@frozen public enum MTMDError: Error, LocalizedError, Sendable {
    case initializationFailed(String)
    case invalidModelPath
    case invalidImagePath
    case imageLoadFailed(String)
    case textAddFailed(String)
    case generationFailed(String)
    case contextNotInitialized
    case generationInProgress
    case noContentToGenerate
    case alreadyInitialized
    case alreadyInitializing
    case outOfMemory
    case timeout(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            return "Initialization failed: \(message)"
        case .invalidModelPath:
            return "Invalid model path."
        case .invalidImagePath:
            return "Invalid image path."
        case .imageLoadFailed(let message):
            return "Image load failed: \(message)"
        case .textAddFailed(let message):
            return "Text add failed: \(message)"
        case .generationFailed(let message):
            return "Generation failed: \(message)"
        case .contextNotInitialized:
            return "Context not initialized. Call initialize first."
        case .generationInProgress:
            return "Generation already in progress."
        case .noContentToGenerate:
            return "Nothing to generate. Add an image or text first."
        case .alreadyInitialized:
            return "Already initialized."
        case .alreadyInitializing:
            return "Initialization already in progress."
        case .outOfMemory:
            return "Out of memory."
        case .timeout(let message):
            return "Timed out: \(message)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
