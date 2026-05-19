# ReceiptLens — Audit Fix Log

Maps each finding in `AUDIT-V2.md` to the change that resolved it.

---

## Critical

### C1 — Nested ObservableObject propagation
**Fix:** `AppState.init` now subscribes to `engine.objectWillChange` and `modelStore.objectWillChange` and re-emits its own `objectWillChange.send()`. SwiftUI views that observe `AppState` now react to engine/model-store state changes.
**Files:** `AppState.swift`.

### C2 — Use-after-free in `reset()`
**Fix:** All C calls now dispatch through a private serial `bridgeQueue` on `MTMDWrapper`. `reset()` first cancels the generation task and awaits its `.value`, then drains the bridge queue with an `async` barrier, then frees the context. No C call can be in flight at the moment of `mb_mtmd_free`.
**Files:** `MTMDWrapper.swift`.

### C3 — `initialize()` lockup after failure
**Fix:** When `mb_mtmd_init` returns `nullptr`, `initializationState` is set to `.failed(...)` before throwing. The state machine is no longer stuck in `.initializing`. The bridge also exposes `mb_mtmd_get_last_init_error()` so the failure message is preserved across the ctx destruction.
**Files:** `MTMDWrapper.swift`, `MBMtmd.mm`, `MBMtmd.h`.

### C4 — Race tapping Analyze during model load
**Fix:** Two layers of defence. (1) `ScannerView` now treats both `.running` and `.loading` as busy and disables the Analyze button (plus Camera/Photos buttons). (2) `MiniCPMEngine.analyze` rejects re-entry with `MiniCPMEngineError.busy`.
**Files:** `ScannerView.swift`, `MiniCPMEngine.swift`.

### C5 — Image prefilled outside user role wrapper
**Fix:** New combined bridge entry `mb_mtmd_prefill_user_image_text(ctx, image_path, text)` constructs the chatml user turn with the image marker INSIDE the user role, then runs a single `mtmd_tokenize` + `mtmd_helper_eval_chunks` pass. The Swift wrapper exposes this as `MTMDWrapper.addUserImageAndText(imagePath:text:)` and `MiniCPMEngine.analyze` uses it in place of the separate `addImage` + `addText` pair. The standalone `mb_mtmd_prefill_image` entry has been removed.
**Files:** `MBMtmd.h`, `MBMtmd.mm`, `MTMDWrapper.swift`, `MiniCPMEngine.swift`.

---

## High

### H1 — Off-actor `context` access
**Fix:** Subsumed by C2's bridge-queue design. `context` is still main-actor-owned, but all reads happen at call entry (on main) and the captured `OpaquePointer` is then handed to a sendable closure on the bridge queue. `reset()` drains the queue before nulling/freeing.
**Files:** `MTMDWrapper.swift`.

### H2 — `deinit` accessing main-actor state
**Fix:** Removed the `deinit` body. `MTMDWrapper` is held for the app's lifetime; teardown goes through explicit `await reset()`. Documented in a comment.
**Files:** `MTMDWrapper.swift`.

### H3 — `mb_mtmd_init` error message unreachable
**Fix:** Added `mb_mtmd_get_last_init_error()` C entry. Failures inside `mb_mtmd_init` write to a static error buffer (mutex-protected). The Swift wrapper reads it on `nullptr` return and surfaces the real message via `MTMDError.initializationFailed`.
**Files:** `MBMtmd.h`, `MBMtmd.mm`, `MTMDWrapper.swift`.

### H4 — `runButton` doesn't disable while `.loading`
**Fix:** Covered by C4 — `engineBusy` includes both `.running` and `.loading`.
**Files:** `ScannerView.swift`.

---

## Medium

### M1 — `stopGeneration()` sets `.completed` not `.cancelled`
**Fix:** `stopGeneration()` only cancels the task. The generation task itself sets `.cancelled` when it exits the loop via `Task.isCancelled`. `runGeneration()` now throws `CancellationError` in that branch.
**Files:** `MTMDWrapper.swift`.

### M2 — `URLSession.shared.download(...)` extension was misleading
**Fix:** Renamed to `URLSession.downloadWithProgress(from:progress:)` as a static method. Call site is `URLSession.downloadWithProgress(...)`, which doesn't pretend to use the shared session.
**Files:** `URLSessionProgress.swift`, `ModelStore.swift`.

### M3 — Progress callback spawned one Task per chunk
**Fix:** Added a `ProgressThrottle` class captured by the progress closure. The state update Task is only spawned when the integer percent changes (≤ 100 spawns per file instead of tens of thousands).
**Files:** `ModelStore.swift`.

### M4 — Redundant `.receive(on: DispatchQueue.main)` in Combine sink
**Fix:** Removed. `MTMDWrapper` is `@MainActor`, so `$fullOutput` already emits on main.
**Files:** `MiniCPMEngine.swift`.

### M5 — `llama_backend_init` never paired with `_free`, called per init
**Fix:** Wrapped in `std::call_once` so it runs exactly once per process. We deliberately don't call `llama_backend_free` — iOS reclaims at process termination.
**Files:** `MBMtmd.mm`.

### M6 — Two polling layers and a 10 ms inner sleep
**Fix:** `MTMDWrapper.runGeneration()` now awaits the generation task's `.value` directly via `withTaskCancellationHandler`. No more 80 ms outer poll, no more 10 ms inner sleep. Tokens are delivered as fast as the model produces them.
**Files:** `MTMDWrapper.swift`, `MiniCPMEngine.swift`.

### M7 — Synchronous JPEG encode + write on main actor
**Fix:** `ImageFileStore.saveForAnalysis(_:)` is now `async` and dispatches resize/encode/write to a detached `Task` at `userInitiated`. AppState awaits it before kicking off the engine.
**Files:** `ImageFileStore.swift`, `AppState.swift`.

### M8 — History in-memory only
**Fix:** `ReceiptScan` is now `Codable` (stores `imageFilename: String`, not an absolute URL). `AppState` persists `scans` to `Documents/scans.json` via a Combine sink on `$scans`, and loads on init.
**Files:** `ReceiptScan.swift`, `AppState.swift`.

### M9 — Scan images accumulate forever on disk
**Fix:** Two paths. (1) `AppState.deleteScans(at:)` calls `imageStore.delete(filename:)` for each removed scan. (2) On init, `AppState` calls `imageStore.pruneOrphans(referencedFilenames:)` to clear any images on disk not referenced by a persisted scan.
**Files:** `AppState.swift`, `ImageFileStore.swift`.

### M10 — Sync image load in `ScanDetailView`
**Fix:** `ScanDetailView` uses `.task(id:)` + `await appState.imageStore.loadImage(at:)` which decodes in a detached background task. A placeholder with `ProgressView()` shows while loading.
**Files:** `HistoryView.swift`, `ImageFileStore.swift`.

---

## Low

### L1 — Dead state in `MTMDWrapper`
**Fix:** Removed `generationQueue`, `lock`, `params`, `currentToken`. (The remaining `bridgeQueue` is a serial DispatchQueue that IS used to serialize C calls — different field, same name pattern.)
**Files:** `MTMDWrapper.swift`.

### L2 — Dead public methods
**Fix:** Removed `cleanup()`, `addFrameInBackground(_:)`, `setImageMaxSliceNums(_:)` from the Swift wrapper, and `mb_mtmd_prefill_frame` and `mb_mtmd_set_image_max_slice_nums` from the C bridge.
**Files:** `MTMDWrapper.swift`, `MBMtmd.h`, `MBMtmd.mm`.

### L3 — Dead model types
**Fix:** Removed `MTMDToken.from(_:index:)`, `MTMDToken.index`, `MTMDToken.timestamp`. Kept `MTMDGenerationState.cancelled` (now used by `stopGeneration` — see M1). Kept `MTMDInitializationState.failed` (used by C3 fix).
**Files:** `MTMDToken.swift`.

### L4 — Trivial private wrappers
**Fix:** Removed `updateInitializationState` and `updateGenerationState`; direct assignment is used inline.
**Files:** `MTMDWrapper.swift`.

### L5 — Hardcoded UI values in `ModelSetupView`
**Fix:** New `EngineConfig` enum holds the runtime constants. `MiniCPMEngine` reads from it to build `MTMDParams`, and `ModelSetupView` reads from it for display. Dropped the meaningless "Device: iPhone 14 Pro target" row; added a "Max output" row driven by `EngineConfig.nPredict`.
**Files:** `Models/EngineConfig.swift` (new), `MiniCPMEngine.swift`, `ModelSetupView.swift`.

### L6 — Hardcoded `Color(red:…)` in RootView
**Fix:** Removed the `.tint(...)` modifier entirely. SwiftUI picks up `AccentColor` from the asset catalog automatically.
**Files:** `RootView.swift`.

### L7 — Chinese error strings and prints
**Fix:** Translated all comments, doc-strings, print statements, and `errorDescription` strings in `MTMDError.swift`, `MTMDWrapper.swift`, `MTMDParams.swift`, `MTMDToken.swift` to English. Verbose generation-loop prints removed.
**Files:** as above.

### L8 — GitHub Actions builds on every push to main
**Fix:** Dropped the `push` trigger. Workflow runs on `workflow_dispatch` only.
**Files:** `.github/workflows/build-unsigned-ios.yml`.

### L9 — `tools/iloader-linux-amd64.AppImage` not in `.gitignore`
**Fix:** Added `tools/` to `.gitignore`.
**Files:** `.gitignore`.

### L10 — Empty `dSYMs/` directories referenced in xcframework Info.plist
**Fix:** Removed the `DebugSymbolsPath` key from both `AvailableLibraries` entries. Deleted the empty `dSYMs/` directories and their `.gitkeep` placeholders.
**Files:** `Vendor/llama.xcframework/Info.plist`, `Vendor/llama.xcframework/ios-arm64/dSYMs/`, `Vendor/llama.xcframework/ios-arm64_x86_64-simulator/dSYMs/`.

---

## UX gaps

### U1 — No way to cancel a running analysis
**Fix:** The Analyze button morphs into a destructive-style "Stop" button while the engine is `.running`. Tapping it calls `engine.stop() → wrapper.stopGeneration() → Task.cancel()`. The generation task observes cancellation between tokens and exits, surfacing `CancellationError` to the engine.
**Files:** `ScannerView.swift`, `MiniCPMEngine.swift`, `MTMDWrapper.swift`.

### U2 — No delete-from-history
**Fix:** `HistoryView` now uses `ForEach` + `.onDelete(perform:)` + `EditButton`. Calls `AppState.deleteScans(at:)`, which also deletes the underlying image file.
**Files:** `HistoryView.swift`, `AppState.swift`.

### U3 — `UIImagePickerController.photoLibrary` deprecated
**Fix:** Split the picker into two types. `CameraPicker` remains, but now only handles the camera source. New `PhotoLibraryPicker` uses `PHPickerViewController` with `PHPickerConfiguration(filter: .images, selectionLimit: 1)` and decodes the picked item via `NSItemProvider.loadObject(ofClass: UIImage.self)`. The photo-library picker no longer requires `NSPhotoLibraryUsageDescription`.
**Files:** `CameraPicker.swift`, `ScannerView.swift`.

### U4 — Image picker reachable mid-analysis
**Fix:** Camera and Photos buttons are now `.disabled(engineBusy)`, matching the Analyze button gating.
**Files:** `ScannerView.swift`.

---

## Summary

All 33 findings addressed. The biggest architectural shifts:

1. **Bridge-queue serialization** in `MTMDWrapper` replaces the ad-hoc `DispatchQueue.global()` calls. All C calls run on one serial queue; `reset()` drains it before freeing. Eliminates the UAF and the off-actor pointer-access race.
2. **`AppState` re-publishes nested observables**, unblocking real-time UI updates for engine and download state.
3. **Combined image+text prefill** in the bridge keeps the chatml user role intact, aligning the prompt format with how MiniCPM-V was trained.
4. **`async` token loop** without polling or sleep, driven via `withTaskCancellationHandler` for clean cancel.
5. **Codable `ReceiptScan` + JSON persistence + orphan pruning** gives a real History tab and bounds disk growth.
