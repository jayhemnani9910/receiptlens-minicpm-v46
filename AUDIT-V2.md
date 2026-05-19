# ReceiptLens Audit — Fresh Read (Opus)

A cold-eyes second pass over the codebase. Grouped by severity. File:line references throughout.

---

## CRITICAL — Things that look broken in normal use

### C1. Nested `ObservableObject` chain is not propagated. Live UI is effectively dead during inference.

**Files:** `AppState.swift:8-10`, `MiniCPMEngine.swift:24-25`, `ModelStore.swift:21`, `ScannerView.swift`, `ModelSetupView.swift`.

`AppState` is the only `@EnvironmentObject` injected, and only one of its properties is `@Published` — `scans`. The other three (`modelStore`, `engine`, `imageStore`) are plain `let`s on nested `ObservableObject`s:

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var scans: [ReceiptScan] = []
    let modelStore = ModelStore()
    let engine = MiniCPMEngine()
    let imageStore = ImageFileStore()
    ...
}
```

SwiftUI does not auto-walk nested `ObservableObject`s. A view observing `appState` only sees `appState.objectWillChange` fire when `scans` is mutated. So in `ScannerView.body`:

- `appState.engine.output` (token streaming) — won't update during generation
- `appState.engine.state == .running` (button disabled state, spinner visibility) — won't update mid-state-change
- `appState.modelStore.state.title` (header status) — won't update during download
- `appState.modelStore.files.isReady` (button disabled state) — same

In practice the user sees **no live feedback at all**. The output appears in one chunk only when `scans.insert(...)` fires `appState.objectWillChange` after the whole analysis finishes. The progress spinner doesn't appear because the body isn't re-evaluated. The button disabled state stays stale.

`MiniCPMEngine.init` even sets up a Combine sink to drive `engine.output` from `wrapper.$fullOutput` — but that update never reaches the view, because the view isn't observing the engine.

Standard fixes: either re-publish in `AppState`'s init (`engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }`), or inject `engine` and `modelStore` as separate environment objects, or hold them as `@StateObject` next to the views that read them.

---

### C2. Use-after-free in `MTMDWrapper.reset()` on a running generation.

**File:** `MTMDWrapper.swift:289-307`.

```swift
public func reset() async {
    stopGeneration()
    if let ctx = context {
        mb_mtmd_free(ctx)
        context = nil
    }
    ...
}
```

`stopGeneration()` only sets `generationTask?.cancel()` and clears the handle. The Swift `Task` cancellation is cooperative — the generation task is currently inside `await mb_mtmd_loop(ctx)` on a background queue. `Task.isCancelled` is only checked at the top of the next loop iteration, after the C call returns.

`reset()` doesn't `await` the task; it calls `mb_mtmd_free(ctx)` immediately. So `mb_mtmd_free` runs concurrently with a possibly-in-progress `mb_mtmd_loop(ctx)`, then a `llama_decode`, on the freed memory. Classic use-after-free.

Triggered by: switching model paths via `MiniCPMEngine.loadIfNeeded` while a generation is in flight, or any code path that calls `wrapper.reset()` mid-stream.

Fix: `await` the generation task before freeing. Store the task and `await task?.value` (or convert to `Task<Void, Error>` and `try? await task?.value`).

---

### C3. `MTMDWrapper.initialize` leaves the wrapper permanently stuck on failure.

**File:** `MTMDWrapper.swift:75-113`.

```swift
updateInitializationState(.initializing)
return try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(...).async {
        ...
        if ctx == nil {
            continuation.resume(throwing: MTMDError.initializationFailed("无法创建 MTMD 上下文"))
            return                          // ← state stays .initializing forever
        }
        Task { @MainActor in
            ...
            self.initializationState = .initialized
            ...
        }
    }
}
```

When `mb_mtmd_init` returns `nullptr` (bad path, OOM, corrupted GGUF, mmproj failed to load), the continuation throws, but nothing resets `initializationState` from `.initializing` back to `.notInitialized` or `.failed`.

Every subsequent call to `initialize` then hits:

```swift
guard initializationState != .initializing else {
    throw MTMDError.alreadyInitializing
}
```

The only escape is `reset()`, but `reset()` is never called from the UI on init failure — `MiniCPMEngine.loadIfNeeded` doesn't catch the error and reset. Restarting the app is the only way out.

Same shape of bug exists for the `.initializing` case if a re-try is attempted in the brief window before the resume — minor in practice, but the failure path is the real problem.

Fix: in the `ctx == nil` branch, also dispatch back to main with `self.initializationState = .failed(...)` (or `.notInitialized`) before resuming the continuation.

---

### C4. Tapping "Analyze" during model load triggers concurrent inference on shared C state.

**Files:** `ScannerView.swift:139`, `AppState.swift:12-34`, `MiniCPMEngine.swift:40-65`.

```swift
.disabled(selectedImage == nil
          || !appState.modelStore.files.isReady
          || appState.engine.state == .running)
```

The disabled predicate doesn't include `.loading`. While the engine state is `.loading` (first-run model init), the Analyze button is enabled. Combine that with C1 (UI doesn't update during state transitions anyway) and the user can fire `analyze()` multiple times before they ever see the "Reading" pill.

Two analyses running concurrently both hit `wrapper.clearKVCacheForNewTurn()` and then race into `addImageInBackground` / `addTextInBackground` / `startGeneration` against the same single-threaded C context. The C state has no internal lock; KV cache, `n_past`, and the live `llama_batch` get scribbled by both callers. Output corruption or crash inside `llama_decode` is the expected result.

Fix: include `.loading` in the disable predicate, and gate `MiniCPMEngine.analyze` on its own re-entrancy check (it currently has none).

---

### C5. Image is prefilled outside the chatml user-role wrapping.

**Files:** `MiniCPMEngine.swift:49-52`, `MBMtmd.mm:444-450`, `MBMtmd.mm:452-519`.

`MiniCPMEngine.analyze` calls in this order:

1. `wrapper.clearKVCacheForNewTurn()`  → `n_past = 0`
2. `wrapper.addImageInBackground(...)` → `prefill_image` tokenizes `mtmd_default_marker()` (just `<__media__>`) + bitmap, decodes with `add_special=true` (adds BOS)
3. `wrapper.addTextInBackground(prompt, role: "user")` → `prefill_text` wraps the prompt as `"<|im_start|>user\n<text><|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"`

So the actual decoded sequence is:

```
[BOS] <image tokens> <|im_start|>user\n <prompt> <|im_end|>\n <|im_start|>assistant\n <think>\n\n</think>\n\n
```

MiniCPM-V's training/instruct format expects the image **inside** the user turn, between `<|im_start|>user\n` and `<|im_end|>`. The current code emits image tokens bare, then opens a user turn afterward. That is out-of-distribution.

The model often still produces reasonable text because the attention is global and the trailing user-role text is well-formed — but extraction quality, refusal behaviour, and instruction-following will be subtly worse than the official Python pipeline. Worth verifying against a reference output.

Fix: either (a) call `prefill_text` first with the wrapper start `"<|im_start|>user\n"`, then `prefill_image` with bare marker, then `prefill_text` with the rest of the user message + assistant header; or (b) extend the bridge so a single `prefill_image_and_text` accepts both the bitmap and the chat-wrapped marker-bearing text and runs them through `mtmd_tokenize` together (this is the pattern mtmd-cli uses).

---

## HIGH — Real bugs, less likely to fire

### H1. `context` pointer is read off-actor from inside background dispatches.

**File:** `MTMDWrapper.swift:130-160`, `162-192`, `198-230`, `337-386`.

`MTMDWrapper` is `@MainActor`, so `private var context: OpaquePointer?` lives on the main actor. The pattern in every prefill method is:

```swift
guard let ctx = context else { throw ... }
... DispatchQueue.global(...).async {
    ... mb_mtmd_prefill_image(ctx, ...)
}
```

The first `let ctx = context` capture happens on main and is fine. But concurrent calls (see C4) plus a `reset()` that nils `context` on main while a background dispatch is mid-flight produces a data race on the property itself. With strict concurrency this would not compile; under Swift 5.9 default it compiles but Thread Sanitizer would flag it.

Lower-severity than C2 (the latter actually frees the memory; this one is just an unsynchronized read of a pointer field), but the underlying issue is the same: cross-actor access of the C context.

---

### H2. `deinit` of `MTMDWrapper` calls main-actor-isolated methods from an unknown thread.

**File:** `MTMDWrapper.swift:57-69`.

```swift
deinit {
    generationTask?.cancel()
    generationTask = nil
    if let ctx = context {
        mb_mtmd_free(ctx)
        context = nil
    }
    ...
}
```

`MTMDWrapper` is `@MainActor`. Deinit can run on any thread, depending on who held the last reference. Accessing `generationTask` and `context` (both main-actor-isolated) from a non-main thread is undefined behaviour under Swift concurrency. In current Swift versions this is a warning at best; it'll get stricter.

In practice, `MiniCPMEngine` is owned by `AppState` which lives for the app lifetime, so `MTMDWrapper.deinit` likely never runs in this app. But the code is wrong.

---

### H3. `mb_mtmd_init` failure error message is unreachable from Swift.

**File:** `MBMtmd.mm:170-301`, `MTMDWrapper.swift:98-100`.

When any step of init fails (model load, llama_context, sampler init, batch_init, vision init), `set_error(ctx.get(), ...)` is called on the in-construction context. Then `return nullptr` triggers the `unique_ptr` destructor and the context is destroyed. The Swift caller gets only:

```swift
throw MTMDError.initializationFailed("无法创建 MTMD 上下文")
```

…a hardcoded generic Chinese string. The real reason (e.g. "Failed to load mmproj from: …") was set on a ctx that no longer exists. It is also written to stderr via `fprintf`, but Swift / iOS users won't see stderr.

Fix options: (a) take a `char ** out_error` argument on `mb_mtmd_init`, write the string there if non-null on failure; or (b) keep a static thread-local last-error buffer in the .mm.

---

### H4. `runButton` doesn't disable while engine is `.loading`.

**File:** `ScannerView.swift:139`.

Already covered under C4 — the disable predicate is just missing the `.loading` case.

---

## MEDIUM — Correctness / lifecycle

### M1. `stopGeneration()` sets state to `.completed`, never `.cancelled`.

**File:** `MTMDWrapper.swift:259-267`.

```swift
if generationState != .completed {
    updateGenerationState(.completed)
}
```

The `.cancelled` case is declared in `MTMDGenerationState` (`MTMDToken.swift:68`) but is never assigned anywhere. UI can't distinguish "model finished naturally" from "user stopped" — both look the same. (And there's no UI to call `stopGeneration()` anyway; see U1.)

---

### M2. `URLSession.download(from:progress:)` extension is misleadingly called on `.shared`.

**File:** `URLSessionProgress.swift:3-13`, used at `ModelStore.swift:61`.

```swift
extension URLSession {
    func download(from url: URL, progress: ...) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: .default, delegate: ..., delegateQueue: nil)
        ...
        return try await session.download(from: url)
    }
}
```

Called as `URLSession.shared.download(from: asset.url) { ... }`. The receiver `.shared` is ignored entirely — a fresh session is constructed every call. Confusing to anyone reading `ModelStore.download(...)`. Make it `static func makeDownload(...)` on `URLSession` or move it off the type entirely.

---

### M3. Progress callback spawns one `Task` per byte chunk.

**File:** `ModelStore.swift:61-67`.

```swift
let (temporaryURL, response) = try await URLSession.shared.download(...) {
    bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
    ...
    Task { @MainActor in
        self.state = .downloading(asset.displayName, progress)
    }
}
```

`urlSession(_:downloadTask:didWriteData:...)` is called by URLSession on every chunk (typically 16 KB). For a 1 GB GGUF that's ~65,000 task allocations, each one hopping to the main actor. Wasteful, and also lets a "late" task land after `state = .ready` has been set, briefly flipping the UI back to `downloading 99%`.

Throttle the publishing (e.g. only emit when integer % changes), or coalesce.

---

### M4. Combine sink uses `.receive(on: DispatchQueue.main)` for a publisher that already fires on main.

**File:** `MiniCPMEngine.swift:31-38`.

```swift
wrapper.$fullOutput
    .receive(on: DispatchQueue.main)
    .sink { [weak self] text in self?.output = text }
```

`wrapper` is `@MainActor`; `$fullOutput` already publishes on main. The hop is redundant and adds one runloop cycle of delay per token. (Doesn't matter for current UX because of C1, but if/when C1 is fixed this becomes user-visible jitter.)

---

### M5. `llama_backend_init` never paired with `llama_backend_free`; called once per ctx init.

**File:** `MBMtmd.mm:180`.

`llama_backend_init()` is called at the top of `mb_mtmd_init`. Every `reset()` + new init re-calls it. `llama_backend_free` is never called. Idempotent in current llama.cpp, but the imbalance is a code smell.

---

### M6. Two redundant polling layers, plus a 10ms inner sleep, for generation completion.

**Files:** `MiniCPMEngine.swift:54-56`, `MTMDWrapper.swift:384`.

Engine:
```swift
while wrapper.generationState == .generating {
    try await Task.sleep(nanoseconds: 80_000_000)   // 80ms outer poll
}
```

Wrapper inner loop:
```swift
try? await Task.sleep(nanoseconds: 10_000_000)      // 10ms per-token sleep
```

The 80ms outer poll exists because `startGeneration()` detaches the generation as a fire-and-forget `Task` instead of returning a `Task<Void, Error>` the caller can `await`. Restructure so the wrapper returns the task (or an `AsyncStream` of tokens) and the engine awaits its `value`.

The 10ms inner sleep has no purpose. SwiftUI updates from the published property, not from a timing signal; the sleep just caps streaming throughput.

---

### M7. Synchronous JPEG encode + file write on main actor.

**File:** `AppState.swift:14`, `ImageFileStore.swift:13-22`.

`AppState.analyze` calls `try imageStore.saveForAnalysis(image)` (synchronous) before its first `await`. `saveForAnalysis` does `UIGraphicsImageRenderer.image(...)`, then `jpegData(compressionQuality: 0.92)`, then `data.write(...)`. All blocking on the main thread. A 12 MP image can stall the UI for tens of ms.

`AppState` is `@MainActor`, so the call chain forces all of this onto main. Move the encode + write off-main, e.g. via `Task.detached` or by making `saveForAnalysis` `async` and dispatching inside it.

---

### M8. Scan history is in-memory only.

**File:** `AppState.swift:6`.

`@Published var scans: [ReceiptScan] = []`. Restarting the app loses everything. The "History" tab implies persistence but doesn't deliver any.

---

### M9. Scanned images accumulate forever in `Documents/Scans/`.

**File:** `ImageFileStore.swift:13-22`.

Every analysis writes a fresh JPEG keyed by `UUID().uuidString`. There is no cleanup, no quota, no eviction. Across many uses, the app's Documents directory grows without bound and shows up in iOS settings as the app eating disk.

---

### M10. `ScanDetailView` reads + decodes the image synchronously on main.

**File:** `HistoryView.swift:49`.

```swift
if let image = UIImage(contentsOfFile: scan.imageURL.path) {
```

Inside `body`. Decodes the JPEG from disk every time the view is laid out, on the main thread.

---

## LOW — Dead code, cosmetics, build hygiene

### L1. Dead state in `MTMDWrapper`.

**File:** `MTMDWrapper.swift`.

- `generationQueue` (line 46) — `DispatchQueue` declared, never used. All dispatches use `DispatchQueue.global(...)`.
- `lock` (line 49) — `NSLock` declared, never used.
- `params` (line 40) — written in `initialize`, cleared in `reset`, never read.

### L2. Dead public methods.

- `MTMDWrapper.cleanup()` (line 330) — thin alias for `reset()`; nothing calls it.
- `MTMDWrapper.addFrameInBackground(_:timeoutSeconds:)` (line 162) — video frame path, no caller.
- `MTMDWrapper.setImageMaxSliceNums(_:)` (line 275) — documented as a no-op on the upstream bridge AND has no caller.

### L3. Dead model types.

- `MTMDToken.from(_:index:)` factory (`MTMDToken.swift:41`) — never called. Also has a sketchy unwrap (`String(cString: cToken.token)` without `!`) that compiles only because the imported C pointer type is implicitly unwrapped.
- `MTMDToken.index: Int?`, `MTMDToken.timestamp: Date` — stored on every token (one allocation per token in the hot path), never read.
- `MTMDGenerationState.cancelled` — never assigned (see M1).
- `MTMDInitializationState.failed(MTMDError)` — declared, never assigned.

### L4. Trivial private wrappers.

`MTMDWrapper.updateInitializationState(_:)` and `updateGenerationState(_:)` (lines 442-449) are one-line setters around direct property assignment. Inline them.

### L5. Hardcoded UI values that drift from the source of truth.

**File:** `ModelSetupView.swift:30-31`.

```swift
LabeledContent("Context", value: "4096")
LabeledContent("Device", value: "iPhone 14 Pro target")
```

"4096" is a string literal that doesn't read from `MTMDParams`. "iPhone 14 Pro target" is a developer note that shouldn't be in the production UI.

### L6. Hardcoded `Color(red:green:blue:)` when an asset already exists.

**Files:** `RootView.swift:21`, `Assets.xcassets/AccentColor.colorset/Contents.json`.

```swift
.tint(Color(red: 0.078, green: 0.443, blue: 0.373))
```

The same RGB triple is already in `AccentColor.colorset`. Use `Color.accentColor` or remove the `.tint(...)` modifier (SwiftUI uses the accent color by default).

### L7. Error strings are in Chinese; surface in an English UI.

**Files:** `MTMDError.swift:56-87`, `MTMDWrapper.swift` (print statements throughout).

`MTMDError.errorDescription` returns Chinese ("初始化失败", "上下文未初始化", etc.). These get bubbled into `engine.state.title` → `StatusPill` text → user-visible UI. The rest of the app is English.

### L8. GitHub Actions builds on every push to `main`.

**File:** `.github/workflows/build-unsigned-ios.yml:5-6`.

```yaml
on:
  workflow_dispatch:
  push:
    branches: [main]
```

`macos-15` runners are billed at 10× the Linux rate. Personal prototype, slow churn → keep `workflow_dispatch` only and drop the push trigger.

### L9. `tools/iloader-linux-amd64.AppImage` (86 MB) is untracked but not gitignored.

**File:** `.gitignore` (and absence of `tools/` therein).

`git status` shows `?? tools/`. One `git add .` away from committing an 86 MB binary into history.

### L10. `Vendor/llama.xcframework/ios-arm64/dSYMs/` is a `.gitkeep`-only directory.

**Files:** `Vendor/llama.xcframework/ios-arm64/dSYMs/.gitkeep`, `Vendor/llama.xcframework/ios-arm64_x86_64-simulator/dSYMs/.gitkeep`.

Documented in the commit message ("Preserve xcframework dSYM directories"), but the dSYMs themselves aren't checked in. Xcode will warn at build time that the referenced dSYM dir is empty. Either ship the real dSYMs (for crash symbolication on TestFlight) or drop the `DebugSymbolsPath` key from `Vendor/llama.xcframework/Info.plist`.

---

## UX gaps

### U1. No way to cancel a running analysis.
`MTMDWrapper.stopGeneration()` works, but no view calls it. Once Analyze is tapped, the user waits.

### U2. No way to delete scans from History.
No swipe-to-delete, no Clear All. Combined with M8 (in-memory), the only delete is to restart the app.

### U3. `UIImagePickerController` for photo library is deprecated.
**File:** `CameraPicker.swift:11`. Replaced by `PHPickerViewController` since iOS 14. Still works on iOS 16 but the deprecation will bite. Note: camera capture still goes through `UIImagePickerController` or `AVCaptureSession`; only the `.photoLibrary` source type is deprecated.

### U4. New image selection isn't gated during a running analysis.
**File:** `ScannerView.swift:89-105`. The Camera and Photos buttons remain tappable while inference is running. A new image swaps into `selectedImage` but the in-flight `analyze()` is using the old image's path. Confusing.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 5 |
| High | 4 |
| Medium | 10 |
| Low | 10 |
| UX gaps | 4 |
| **Total** | **33** |

The two findings most likely to ruin your day right now:

- **C1**: live UI updates don't work; the streaming-token UX you think you've built is silently disabled. Token-by-token output appears all-at-once after generation completes.
- **C2 / C4 / C3**: any path that triggers `reset()` or concurrent `analyze()` calls puts the C state into an unrecoverable bad state, leading either to a crash or to a "Loading model" pill that never goes away until app restart.
