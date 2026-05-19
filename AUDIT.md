# ReceiptLens Audit

Findings from a cold read of the codebase. Grouped by severity.

---

## Actual Bugs / Things That Will Break

### 1. Data race on `context` pointer
**File:** `MTMDWrapper.swift`

`MTMDWrapper` is `@MainActor`, so `context: OpaquePointer?` lives on the main actor. But `addImageInBackground`, `addTextInBackground`, and `addFrameInBackground` all read `context` inside a `DispatchQueue.global().async` block — off the main actor, no synchronization. Meanwhile `reset()` writes `context = nil` on main. This is a data race: the background thread can be mid-read when the main thread nulls the pointer.

In practice it doesn't crash because the app never calls `reset()` while inference is running, but the race is real and would be flagged by the thread sanitizer.

---

### 2. `generate` loop 10ms sleep caps token throughput unnecessarily
**File:** `MTMDWrapper.swift`, `performGeneration()` line 384

```swift
try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
```

This sleep is inside the per-token generation loop. At one token per 10ms, max throughput is 100 tok/s from the Swift side alone, regardless of how fast the model actually is. On a modern iPhone with GPU, `mb_mtmd_loop` often returns in microseconds per token. The sleep serves no purpose — SwiftUI re-renders from the `@Published` property, not from a timing signal.

---

### 3. `MiniCPMEngine.analyze()` polls state with 80ms sleep
**File:** `MiniCPMEngine.swift`, lines 54–57

```swift
while wrapper.generationState == .generating {
    try await Task.sleep(nanoseconds: 80_000_000)
}
```

Polling `generationState` in a sleep loop is redundant — `generationState` is a `@Published` property already. The engine could `await` completion via `AsyncStream` or a `withCheckedContinuation` instead. As-is, completion is detected up to 80ms late, and the pattern stacks on top of the 10ms inner sleep from issue 2.

---

### 4. Image file I/O on the main actor
**File:** `AppState.swift`, `ImageFileStore.swift`

`AppState.analyze()` calls `imageStore.saveForAnalysis(image)` synchronously. `saveForAnalysis` does JPEG encoding (`jpegData`) and a file write (`data.write`) — both blocking — on the main actor. For a 12MP photo (even after downscaling to 1600px) this can stall the UI for tens of milliseconds.

---

## Dead Code

### 5. `MTMDWrapper.generationQueue` — never used
**File:** `MTMDWrapper.swift`, line 46

```swift
private let generationQueue = DispatchQueue(label: "com.mtmd.generation", qos: .userInitiated)
```

All actual dispatch goes to `DispatchQueue.global(qos: .userInitiated)`. This queue is declared but never referenced.

---

### 6. `MTMDWrapper.lock` — never used
**File:** `MTMDWrapper.swift`, line 49

```swift
private let lock = NSLock()
```

Never locked or unlocked anywhere in `MTMDWrapper`. The watchdog in `runWithWatchdog` uses its own local `ResumeState.lock`, not this one.

---

### 7. `MTMDToken.from(_:index:)` — never called
**File:** `MTMDToken.swift`, line 41

The static factory `MTMDToken.from(_ cToken: mb_mtmd_token, index: Int?)` exists but `performGeneration()` constructs `MTMDToken` manually. This factory is dead.

---

### 8. `MTMDToken.index` and `MTMDToken.timestamp` — never read
**File:** `MTMDToken.swift`

`index: Int?` and `timestamp: Date` are stored on every token but nothing in the app reads them. `currentToken` is published but only `fullOutput` and `generationState` are actually observed.

---

### 9. `MTMDWrapper.addFrameInBackground()` — nothing calls it
**File:** `MTMDWrapper.swift`, line 162

The video-frame prefill path (`addFrameInBackground` → `mb_mtmd_prefill_frame`) is fully implemented but no view or service ever invokes it. There's no video feature in the app.

---

### 10. `MTMDWrapper.cleanup()` — nothing calls it
**File:** `MTMDWrapper.swift`, line 330

```swift
public func cleanup() async {
    await reset()
}
```

A thin alias for `reset()` that's never called. `reset()` itself is only called from `loadIfNeeded` when switching models.

---

### 11. `MTMDGenerationState.cancelled` — never set
**File:** `MTMDToken.swift`, line 68

The `.cancelled` case exists in `MTMDGenerationState` but `stopGeneration()` sets state to `.completed`, not `.cancelled`. The case is unreachable.

---

### 12. `MTMDWrapper.updateInitializationState` and `updateGenerationState` — trivial no-value wrappers
**File:** `MTMDWrapper.swift`, lines 442–448

Both methods do nothing except assign a property:
```swift
private func updateInitializationState(_ state: MTMDInitializationState) {
    initializationState = state
}
```
Since the class is `@MainActor`, direct assignment is equivalent. These methods exist without reason.

---

## Missing Features / UX Gaps

### 13. History is in-memory only — lost on restart
**File:** `AppState.swift`

`scans: [ReceiptScan]` lives in RAM. Every app launch starts with an empty list. The "History" tab implies persistence but delivers none. Needs `Codable` + file persistence, or SwiftData.

---

### 14. No way to stop a running analysis
`MiniCPMEngine` and `MTMDWrapper.stopGeneration()` both exist and work, but there's no button in `ScannerView` to call them. Once "Analyze" is tapped, the user is stuck waiting.

---

### 15. No way to delete scans from History
`HistoryView` shows a list but has no swipe-to-delete and no "Clear All". Since scans are in-memory, clearing them requires restarting the app.

---

### 16. Scanned images accumulate on disk forever
**File:** `ImageFileStore.swift`

Every `analyze()` call writes a JPEG to `Documents/Scans/`. There's no cleanup, no size cap, no eviction. After hundreds of uses this folder grows unbounded.

---

### 17. `ScanDetailView` loads image from disk synchronously on the main thread
**File:** `HistoryView.swift`, line 49

```swift
if let image = UIImage(contentsOfFile: scan.imageURL.path) {
```

Synchronous file read + image decode in the view body. For large images this blocks the main thread and produces visible stutter on navigation.

---

## Hardcoded / Stale UI Values

### 18. `ModelSetupView` shows hardcoded `"4096"` and `"iPhone 14 Pro target"`
**File:** `ModelSetupView.swift`, lines 30–31

```swift
LabeledContent("Context", value: "4096")
LabeledContent("Device", value: "iPhone 14 Pro target")
```

Context window is a string literal that doesn't reflect the actual `nCtx` value from `MTMDParams`. "iPhone 14 Pro target" is a dev-time note that leaked into the UI.

---

### 19. Tint color hardcoded as raw RGB in `RootView`
**File:** `RootView.swift`, line 21

```swift
.tint(Color(red: 0.078, green: 0.443, blue: 0.373))
```

Should be an `AccentColor` asset (the project already has an empty `AccentColor.colorset` in `Assets.xcassets`). Using the asset would respect dark mode automatically and be one place to change the colour.

---

## Build / CI

### 20. GitHub Actions triggers on every push to `main`
**File:** `.github/workflows/build-unsigned-ios.yml`

```yaml
on:
  workflow_dispatch:
  push:
    branches: [main]
```

Every commit burns a macOS runner (the slowest, most expensive GitHub-hosted runner). For a personal prototype, removing the `push` trigger and keeping only `workflow_dispatch` means you build when you want to, not on every typo fix.

---

### 21. `tools/iloader-linux-amd64.AppImage` (86 MB) is not in `.gitignore`
**File:** `.gitignore`

The 86 MB binary is untracked (`?? tools/`) but not listed in `.gitignore`. One accidental `git add .` commits an 86 MB binary into history. Add `tools/` to `.gitignore`.

---

## Deprecated API

### 22. `UIImagePickerController` for photo library is deprecated
**File:** `CameraPicker.swift`

`UIImagePickerController` with `.photoLibrary` source type is deprecated since iOS 14. The replacement is `PHPickerViewController`, which also doesn't require `NSPhotoLibraryUsageDescription` (it uses the system picker in-process). Camera use still requires `UIImagePickerController` or `AVCaptureSession` — that part is fine.

---

## Minor / Cosmetic

### 23. NativeBridge files use Chinese in comments and `print` statements
**Files:** `MTMDWrapper.swift`, `MTMDParams.swift`, `MTMDError.swift`, `MTMDToken.swift`

All comments, print strings, and error messages are in Chinese (carried over from the OpenBMB iOS demo source). This is readable to a Mandarin speaker but opaque to anyone else. Not a functional issue, but worth noting before the code is shared or handed off.

---

## Summary

| Category | Count |
|----------|-------|
| Bugs / will break | 4 |
| Dead code | 8 |
| Missing features / UX | 5 |
| Hardcoded UI values | 2 |
| Build / CI | 2 |
| Deprecated API | 1 |
| Minor | 1 |
| **Total** | **23** |
