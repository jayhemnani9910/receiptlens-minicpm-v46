import Foundation

@frozen public struct MTMDToken: Sendable {
    public let content: String
    public let isEnd: Bool

    public init(content: String, isEnd: Bool) {
        self.content = content
        self.isEnd = isEnd
    }

    public static let empty = MTMDToken(content: "", isEnd: false)
}

@frozen public enum MTMDGenerationState: Equatable, Sendable {
    case idle
    case generating
    case completed
    case cancelled
    case failed(MTMDError)

    public static func == (lhs: MTMDGenerationState, rhs: MTMDGenerationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.generating, .generating),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

@frozen public enum MTMDInitializationState: Equatable, Sendable {
    case notInitialized
    case initializing
    case initialized
    case failed(MTMDError)

    public static func == (lhs: MTMDInitializationState, rhs: MTMDInitializationState) -> Bool {
        switch (lhs, rhs) {
        case (.notInitialized, .notInitialized),
             (.initializing, .initializing),
             (.initialized, .initialized):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}
