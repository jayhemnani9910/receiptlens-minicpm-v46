import Foundation

enum EngineConfig {
    static let nCtx = 4096
    static let nPredict = 768
    static let nThreads = 4
    static let temperature: Float = 0.2
    static let nUbatch = 256
    static let imageMaxTokens = 256
    static let imageMaxSliceNums = -1
}
