import Foundation
import llama

@frozen public struct MTMDParams: Sendable {
    public let modelPath: String
    public let mmprojPath: String
    public let nPredict: Int
    public let nCtx: Int
    public let nThreads: Int
    public let temperature: Float
    public let useGPU: Bool
    public let mmprojUseGPU: Bool
    public let warmup: Bool

    /// Physical batch size for `llama_context` (`n_ubatch`). Dominates the GPU
    /// compute buffer; tune down on low-memory devices. `0` means the bridge
    /// picks its own default (currently 512).
    public let nUbatch: Int

    /// Slice-count UX value carried from the legacy slider. Not propagated to
    /// the bridge under upstream master (the master mtmd API uses a
    /// token-budget knob, see `imageMaxTokens`). Kept on the type so callers
    /// can pass `-1` to mean "model default" without breaking source.
    public let imageMaxSliceNums: Int

    /// Vision token budget (`image_max_tokens`). `-1` means model default.
    /// Lower values reduce per-image memory at the cost of detail.
    public let imageMaxTokens: Int

    public init(
        modelPath: String,
        mmprojPath: String,
        nPredict: Int = 100,
        nCtx: Int = 4096,
        nThreads: Int = 4,
        temperature: Float = 0.7,
        useGPU: Bool = true,
        mmprojUseGPU: Bool = true,
        warmup: Bool = true,
        nUbatch: Int = 0,
        imageMaxSliceNums: Int = -1,
        imageMaxTokens: Int = -1
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.nPredict = nPredict
        self.nCtx = nCtx
        self.nThreads = nThreads
        self.temperature = temperature
        self.useGPU = useGPU
        self.mmprojUseGPU = mmprojUseGPU
        self.warmup = warmup
        self.nUbatch = nUbatch
        self.imageMaxSliceNums = imageMaxSliceNums
        self.imageMaxTokens = imageMaxTokens
    }

    internal func toCParams() -> mb_mtmd_params {
        var params = mb_mtmd_params_default()
        params.n_predict        = Int32(nPredict)
        params.n_ctx            = Int32(nCtx)
        params.n_ubatch         = Int32(nUbatch)
        params.n_threads        = Int32(nThreads)
        params.temperature      = temperature
        params.use_gpu          = useGPU
        params.mmproj_use_gpu   = mmprojUseGPU
        params.warmup           = warmup
        params.image_max_tokens = Int32(imageMaxTokens)
        return params
    }
}
