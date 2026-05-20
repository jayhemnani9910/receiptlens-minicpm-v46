# ReceiptLens UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild ReceiptLens's UI as an iOS-native premium app (hero + bottom-sheet scan flow, date-bucketed searchable history, scan detail with zoom, settings sheet) and add share/export, history search, and "ask again" re-run.

**Architecture:** SwiftUI over the existing `AppState` / `MiniCPMEngine` / `ModelStore` stack (unchanged below the view layer, plus one engine cancellation fix). Two tabs (Scan, History) with Settings as a gear-icon sheet. A single shared `AnalyzeSheet` drives both first-run analysis and "ask again". Pure presentation logic (date bucketing, search filter, thumbnails) is factored into free functions / a cache service so it is verifiable by reading.

**Tech Stack:** Swift 5.9, SwiftUI (iOS 16 deployment target), XcodeGen (`project.yml` globs `ReceiptLens/`, so new `.swift` files are picked up by `xcodegen generate` with no manifest edit), llama.cpp via the existing Obj-C++ bridge.

**Design source of truth:** `docs/superpowers/specs/2026-05-19-receiptlens-redesign-design.md`.

---

## Verification strategy (read this before starting)

This repo has **no local macOS toolchain** (developer works on Linux) and **no XCTest target**. So:

- **Compile gate:** the `.github/workflows/build-unsigned-ios.yml` workflow builds on `macos-15` / Xcode 16. A green run = everything compiles and links. This is the authoritative "tests pass" signal for this plan. Run it once at the end (Task 14), not per task, because intermediate half-rewritten states will not compile.
- **Visual gate:** the developer sideloads the resulting IPA and checks each screen on device.
- **Logic gate:** date bucketing, search filtering, and thumbnail downsampling are written as pure free functions / a standalone service with explicit reasoning, so they can be confirmed by reading. (A future XCTest target could cover them; out of scope here.)

Each task still ends in its own commit (frequent commits). Where a normal plan says "run the test", here that means "confirm the code reads correctly against the spec and the snippet"; the CI build in Task 14 is the real check.

**Git:** repo root is `ReceiptLens/` (not the parent folder). All `git` commands below run from `ReceiptLens/`. Do not push or open a PR without explicit approval (per global Git Safety rules); Task 14 pushes only because pushing is how CI builds — confirm with the user first.

---

## File structure

**New files**

| File | Responsibility |
|---|---|
| `ReceiptLens/Models/HistorySectioning.swift` | Pure date-bucket + search-filter logic for History |
| `ReceiptLens/Services/ThumbnailCache.swift` | NSCache-backed lazy downsampled thumbnail loader |
| `ReceiptLens/Views/Components/ModeChip.swift` | Reusable mode capsule (selected = accent, else material) |
| `ReceiptLens/Views/AnalyzeSheet.swift` | Shared bottom sheet: input → reading → done/error. Used by Scan and by Ask-again |
| `ReceiptLens/Views/ZoomableImageView.swift` | Full-screen pinch-to-zoom image viewer |
| `ReceiptLens/Views/ScanDetailView.swift` | Scan detail screen (pulled out of HistoryView) |
| `ReceiptLens/Views/SettingsView.swift` | Settings sheet (Model / Defaults / Storage / About) |

**Modified files**

| File | Change |
|---|---|
| `ReceiptLens/Models/AnalysisMode.swift` | Add `tint` color + `label` for per-mode glyph identity |
| `ReceiptLens/Services/MiniCPMEngine.swift` | Treat cancellation as a normal stop (return partial, state → `.ready`) |
| `ReceiptLens/AppState.swift` | Add `@AppStorage` default mode, `clearAllScans()`, thumbnail-cache eviction on delete |
| `ReceiptLens/Views/RootView.swift` | Two tabs only; Model tab removed |
| `ReceiptLens/Views/ScannerView.swift` | Full rewrite: hero states + chips + Analyze + present `AnalyzeSheet` |
| `ReceiptLens/Views/HistoryView.swift` | Date buckets, `.searchable`, thumbnail rows; inline `ScanDetailView` removed |

**Deleted file**

| File | Reason |
|---|---|
| `ReceiptLens/Views/ModelSetupView.swift` | Replaced by `SettingsView` |

---

## Task 1: AnalysisMode visual identity

**Files:**
- Modify: `ReceiptLens/Models/AnalysisMode.swift`

The chips' *selected* state uses the single app accent (Section 1). `tint` here is only for the small mode glyph in History rows / Detail pill, kept subtle so it does not contradict the single-accent rule.

- [ ] **Step 1: Add `tint` and `label` to the enum**

Replace the whole file with:

```swift
import SwiftUI

enum AnalysisMode: String, CaseIterable, Identifiable, Codable {
    case receipt = "Receipt"
    case document = "Document"
    case screen = "Screen"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .receipt: "receipt"
        case .document: "doc.text.viewfinder"
        case .screen: "rectangle.and.text.magnifyingglass"
        }
    }

    /// Subtle per-mode glyph tint for History rows and the Detail pill.
    /// Chip *selection* still uses the single app accent.
    var tint: Color {
        switch self {
        case .receipt: .teal
        case .document: .indigo
        case .screen: .orange
        }
    }

    var label: String { rawValue }
}
```

- [ ] **Step 2: Confirm**

`Color` requires `import SwiftUI` (was `import Foundation`). No other file references a removed symbol. Reads correctly against spec.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Models/AnalysisMode.swift
git commit -m "Add per-mode tint and label to AnalysisMode"
```

---

## Task 2: ThumbnailCache service

**Files:**
- Create: `ReceiptLens/Services/ThumbnailCache.swift`

Lazy, downsampled, in-memory. Keyed by filename. Decodes off-main via ImageIO thumbnail generation (cheaper than decoding the full 1600px JPEG for a 56pt row).

- [ ] **Step 1: Write the service**

```swift
import UIKit
import ImageIO

/// In-memory, downsampled thumbnail cache for History rows.
/// Thread-safe via NSCache; decoding happens off the main actor.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    /// Returns a cached thumbnail or decodes one. `maxPixel` is in points;
    /// it is multiplied by the screen scale internally.
    func thumbnail(for url: URL, maxPixel: CGFloat = 120) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let scale = await UIScreen.main.scale
        let image = await Task.detached(priority: .utility) {
            Self.downsample(url: url, maxPixelSize: maxPixel * scale)
        }.value

        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func remove(filename: String) {
        cache.removeObject(forKey: filename as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func downsample(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 2: Confirm**

`UIScreen.main.scale` is `@MainActor`-isolated under Swift 6 strict concurrency; reading it with `await` before the detached task keeps the detached closure free of main-actor access. Reads correctly.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Services/ThumbnailCache.swift
git commit -m "Add downsampling thumbnail cache for history rows"
```

---

## Task 3: History sectioning + search logic

**Files:**
- Create: `ReceiptLens/Models/HistorySectioning.swift`

Pure functions, no SwiftUI. Date buckets: Today / Yesterday / Previous 7 Days / Earlier.

- [ ] **Step 1: Write the logic**

```swift
import Foundation

enum HistoryBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case previous7 = "Previous 7 Days"
    case earlier = "Earlier"
}

enum HistorySectioning {
    static func bucket(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HistoryBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let startOfToday = calendar.startOfDay(for: now)
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= sevenDaysAgo {
            return .previous7
        }
        return .earlier
    }

    /// Newest first within each bucket; buckets in fixed display order;
    /// empty buckets omitted.
    static func grouped(
        _ scans: [ReceiptScan],
        now: Date = Date()
    ) -> [(bucket: HistoryBucket, scans: [ReceiptScan])] {
        let sorted = scans.sorted { $0.createdAt > $1.createdAt }
        var map: [HistoryBucket: [ReceiptScan]] = [:]
        for scan in sorted {
            map[bucket(for: scan.createdAt, now: now), default: []].append(scan)
        }
        return HistoryBucket.allCases.compactMap { bucket in
            guard let scans = map[bucket], !scans.isEmpty else { return nil }
            return (bucket, scans)
        }
    }

    /// Case-insensitive match on output text or mode name. Blank query passes all.
    static func filter(_ scans: [ReceiptScan], query: String) -> [ReceiptScan] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return scans }
        return scans.filter {
            $0.output.lowercased().contains(trimmed)
                || $0.mode.rawValue.lowercased().contains(trimmed)
        }
    }
}
```

- [ ] **Step 2: Confirm by reasoning**

- A scan from 10 minutes ago → `isDateInToday` true → `.today`. ✓
- A scan from 3 days ago → not today/yesterday, `>= now-7d` → `.previous7`. ✓
- A scan from 20 days ago → `.earlier`. ✓
- `filter([...], "")` returns input unchanged. ✓

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Models/HistorySectioning.swift
git commit -m "Add history date bucketing and search filter logic"
```

---

## Task 4: Engine treats cancellation as a normal stop

**Files:**
- Modify: `ReceiptLens/Services/MiniCPMEngine.swift:53-62`

Today, `stop()` cancels generation, which makes `runGeneration()` throw `CancellationError`, which the catch turns into `state = .failed(...)`. The redesign's Stop button must keep partial output and return to a non-error state so the sheet shows the "done" action row, not the error layout.

- [ ] **Step 1: Update the catch in `analyze`**

Replace lines 53-62 (the `do { ... } catch { ... }` block inside `analyze`) with:

```swift
        do {
            await wrapper.clearKVCacheForNewTurn()
            try await wrapper.addUserImageAndText(imagePath: imageURL.path, text: prompt)
            let result = try await wrapper.runGeneration()
            state = .ready
            return result
        } catch is CancellationError {
            // User tapped Stop. Keep whatever streamed so far; this is not a failure.
            state = .ready
            return output
        } catch {
            state = .failed("Analysis failed: \(error.localizedDescription)")
            throw error
        }
```

- [ ] **Step 2: Confirm**

`output` is the `@Published` mirror of `wrapper.$fullOutput`, so it holds the partial text at cancel time. On cancel, `analyze` now returns normally with partial text and `state == .ready`; the AppState caller (Task 5) still inserts a scan from that return value.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Services/MiniCPMEngine.swift
git commit -m "Treat generation cancellation as a normal stop, not a failure"
```

---

## Task 5: AppState — default mode, clear-all, thumbnail eviction

**Files:**
- Modify: `ReceiptLens/AppState.swift`

`@AppStorage` cannot live on a plain `ObservableObject` cleanly, so the default-mode value is stored via `UserDefaults` behind a computed property; the Settings `Picker` and Scan screen use the SwiftUI `@AppStorage("defaultMode")` wrapper directly (same key). They share the key `"defaultMode"` storing the mode `rawValue`.

- [ ] **Step 1: Add clear-all and thumbnail eviction; evict on delete**

Replace `deleteScans(at:)` (lines 70-78) with:

```swift
    func deleteScans(at offsets: IndexSet) {
        let removed = offsets.map { scans[$0] }
        scans.remove(atOffsets: offsets)
        evictAndDelete(removed)
    }

    func deleteScan(_ scan: ReceiptScan) {
        scans.removeAll { $0.id == scan.id }
        evictAndDelete([scan])
    }

    func clearAllScans() {
        let removed = scans
        scans.removeAll()
        evictAndDelete(removed)
    }

    private func evictAndDelete(_ removed: [ReceiptScan]) {
        for scan in removed {
            ThumbnailCache.shared.remove(filename: scan.imageFilename)
        }
        Task { [imageStore] in
            for scan in removed {
                try? await imageStore.delete(filename: scan.imageFilename)
            }
        }
    }
```

- [ ] **Step 2: Confirm**

`deleteScan(_:)` supports the Detail screen's ⋯→Delete and swipe in non-edit mode by id. `clearAllScans()` backs Settings → Clear all history. Thumbnail cache is evicted synchronously before the async file delete. `analyze(image:mode:customPrompt:)` is unchanged and still inserts the new scan (works for both Scan and Ask-again, since Ask-again passes the loaded `UIImage`).

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/AppState.swift
git commit -m "Add clear-all, single-scan delete, and thumbnail eviction to AppState"
```

---

## Task 6: ModeChip component

**Files:**
- Create: `ReceiptLens/Views/Components/ModeChip.swift`

- [ ] **Step 1: Write the chip**

```swift
import SwiftUI

struct ModeChip: View {
    let mode: AnalysisMode
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Label(mode.label, systemImage: mode.systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .scaleEffect(pressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel(mode.label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }
}

struct ModeChipRow: View {
    @Binding var selection: AnalysisMode
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalysisMode.allCases) { mode in
                ModeChip(mode: mode, isSelected: selection == mode, isEnabled: isEnabled) {
                    selection = mode
                }
            }
        }
    }
}
```

- [ ] **Step 2: Confirm**

Selected = accent fill + white text; unselected = `.regularMaterial`. Dimmed + untappable when `isEnabled == false` (Empty state). Press scales to 0.96 per Section 1.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/Components/ModeChip.swift
git commit -m "Add ModeChip and ModeChipRow components"
```

---

## Task 7: AnalyzeSheet (shared streaming sheet)

**Files:**
- Create: `ReceiptLens/Views/AnalyzeSheet.swift`

Drives both first-run analysis (Scan) and Ask-again (Detail). Phases derive from `appState.engine.state` plus a local flag for the optional pre-input step.

- [ ] **Step 1: Write the sheet**

```swift
import SwiftUI

struct AnalyzeSheet: View {
    /// The image to analyze (already in memory). For Scan this is the just-picked
    /// photo; for Ask-again it is the loaded detail image.
    let image: UIImage
    /// When true, the sheet opens on an input step (mode + prompt) before running.
    /// Scan passes false (it runs immediately); Ask-again passes true.
    let startWithInput: Bool
    @Binding var mode: AnalysisMode
    @Binding var customPrompt: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase
    @State private var promptExpanded = false

    enum Phase { case input, running, done, failed }

    init(image: UIImage, startWithInput: Bool,
         mode: Binding<AnalysisMode>, customPrompt: Binding<String>) {
        self.image = image
        self.startWithInput = startWithInput
        self._mode = mode
        self._customPrompt = customPrompt
        self._phase = State(initialValue: startWithInput ? .input : .running)
    }

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .input:    inputContent
            case .running:  runningContent
            case .done:     resultContent(error: false)
            case .failed:   resultContent(error: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .running)
        .task(id: phaseRunToken) {
            if phase == .running { await run() }
        }
        .onChange(of: appState.engine.state) { newState in
            switch newState {
            case .ready where phase == .running: phase = .done
            case .failed where phase == .running: phase = .failed
            default: break
            }
        }
    }

    // Re-trigger `.task` only when we (re)enter running.
    private var phaseRunToken: Int { phase == .running ? runCounter : -1 }
    @State private var runCounter = 0

    private func run() async {
        await appState.analyze(image: image, mode: mode, customPrompt: customPrompt)
    }

    // MARK: Input (Ask-again)

    private var inputContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Ask again").font(.title2.weight(.semibold))
                Spacer()
            }
            ModeChipRow(selection: $mode)
            promptDisclosure
            Button {
                runCounter += 1
                phase = .running
            } label: {
                Label("Analyze", systemImage: "sparkles")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            Spacer(minLength: 0)
        }
    }

    private var promptDisclosure: some View {
        DisclosureGroup("Custom prompt", isExpanded: $promptExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $customPrompt)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Leave blank to use the built-in \(mode.label.lowercased()) prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    // MARK: Running

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reading\(dots)").font(.title2.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    appState.engine.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            ScrollView {
                Text(appState.engine.output.isEmpty ? " " : appState.engine.output)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(nil, value: appState.engine.output)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onAppear { animateDots() }
    }

    @State private var dots = ""
    private func animateDots() {
        guard phase == .running else { return }
        let states = ["", ".", "..", "..."]
        Task { @MainActor in
            var i = 0
            while phase == .running {
                dots = states[i % states.count]; i += 1
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            dots = ""
        }
    }

    // MARK: Done / Failed

    private func resultContent(error: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.red)
                    Text("Couldn't read this").font(.title2.weight(.semibold))
                    Text(appState.engine.state.title)
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Label(mode.label, systemImage: mode.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode.tint)
                    Text("· just now").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView {
                    Text(appState.engine.output)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 12) {
                if error {
                    Button { runCounter += 1; phase = .running } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule())
                } else {
                    ShareLink(item: appState.engine.output) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule())

                    Button {
                        customPrompt = ""
                        promptExpanded = false
                        phase = .input
                    } label: {
                        Label("Ask again", systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).clipShape(Capsule())
                }

                Button("Done") { dismiss() }
                    .frame(minHeight: 44)
            }
        }
    }
}
```

- [ ] **Step 2: Confirm against spec**

- Scan opens with `startWithInput: false` → goes straight to `.running`, kicks `run()` via `.task`. ✓
- Stop → `engine.stop()` → cancellation → engine `.ready` (Task 4) → `onChange` moves to `.done` with partial text. ✓
- `.done` shows Share (`ShareLink`) / Ask again / Done. Ask again → `.input`. ✓
- `.failed` shows the error layout with Try again / Done. ✓
- `interactiveDismissDisabled` only while running. ✓
- Streaming text uses `.animation(nil, ...)` so it does not reflow per token (Section 1). ✓

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/AnalyzeSheet.swift
git commit -m "Add shared AnalyzeSheet for streaming analysis and ask-again"
```

---

## Task 8: ScannerView rewrite (hero + chips + Analyze)

**Files:**
- Modify: `ReceiptLens/Views/ScannerView.swift` (full replacement)

States A (empty), B (has image), and presents `AnalyzeSheet` for C. Default mode read from `@AppStorage`.

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI
import UIKit

struct ScannerView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("defaultMode") private var defaultModeRaw = AnalysisMode.receipt.rawValue

    @State private var mode: AnalysisMode = .receipt
    @State private var selectedImage: UIImage?
    @State private var customPrompt = ""
    @State private var promptExpanded = false
    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    @State private var showingSheet = false
    @State private var showingSettings = false
    @State private var showingModelAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if selectedImage == nil { emptyState } else { imageState }
            }
            .navigationTitle("ReceiptLens")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showingCamera) { CameraPicker(image: $selectedImage) }
            .sheet(isPresented: $showingPhotoLibrary) { PhotoLibraryPicker(image: $selectedImage) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingSheet, onDismiss: resetAfterSheet) {
                if let selectedImage {
                    AnalyzeSheet(image: selectedImage, startWithInput: false,
                                 mode: $mode, customPrompt: $customPrompt)
                }
            }
            .alert("Model not downloaded yet", isPresented: $showingModelAlert) {
                Button("Open Settings") { showingSettings = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download MiniCPM-V 4.6 (~1.6 GB) in Settings to use this feature.")
            }
            .onAppear {
                if let stored = AnalysisMode(rawValue: defaultModeRaw) { mode = stored }
            }
        }
    }

    // MARK: State A — empty

    private var emptyState: some View {
        VStack(spacing: 24) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 52, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("Add an image").font(.title2.weight(.semibold))
                        Text("Receipt, document, or screenshot")
                            .font(.body).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxHeight: .infinity)
            ModeChipRow(selection: $mode, isEnabled: false)
        }
        .padding(24)
    }

    // MARK: State B — has image

    private var imageState: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: selectedImage!)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    Button {
                        selectedImage = nil
                        customPrompt = ""
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .padding(10).background(.thinMaterial, in: Circle())
                    }
                    .padding(12)
                    .accessibilityLabel("Retake")
                }
                ModeChipRow(selection: $mode)
                promptDisclosure
            }
            .padding(24)
        }
    }

    private var promptDisclosure: some View {
        DisclosureGroup("Custom prompt", isExpanded: $promptExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $customPrompt)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Leave blank to use the built-in \(mode.label.lowercased()) prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
        .tint(.primary)
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        if selectedImage == nil {
            HStack(spacing: 12) {
                Button { showingCamera = true } label: {
                    Label("Camera", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                Button { showingPhotoLibrary = true } label: {
                    Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
            }
            .clipShape(Capsule())
            .padding(.horizontal, 24).padding(.bottom, 8)
        } else {
            Button(action: startAnalyze) {
                Label("Analyze", systemImage: "sparkles")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
    }

    private func startAnalyze() {
        guard appState.modelStore.files.isReady else { showingModelAlert = true; return }
        showingSheet = true
    }

    private func resetAfterSheet() {
        selectedImage = nil
        customPrompt = ""
        promptExpanded = false
    }
}
```

- [ ] **Step 2: Confirm against spec**

- Empty: dimmed untappable chips, Camera (prominent) + Photos (bordered) pinned bottom. ✓
- Has-image: hero image with retake overlay, active chips, collapsible prompt, Analyze pinned. ✓
- Analyze → model guard alert if not ready, else present `AnalyzeSheet`. ✓
- On sheet dismiss (Done), Scan resets to State A. The scan already persisted when generation completed (inside `appState.analyze`). ✓
- The two equal-width bottom pills use one `Capsule` clip around the HStack; both buttons fill width equally. ✓

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/ScannerView.swift
git commit -m "Rewrite ScannerView as hero + chips + analyze sheet flow"
```

---

## Task 9: ZoomableImageView

**Files:**
- Create: `ReceiptLens/Views/ZoomableImageView.swift`

- [ ] **Step 1: Write the viewer**

```swift
import SwiftUI

struct ZoomableImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = min(max(scale * value, 1), 5)
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5 }
                    }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
```

- [ ] **Step 2: Confirm**

Pinch to zoom (clamped 1–5x), double-tap toggles 1x/2.5x, close button dismisses the `.fullScreenCover`.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/ZoomableImageView.swift
git commit -m "Add full-screen zoomable image viewer"
```

---

## Task 10: ScanDetailView (own file)

**Files:**
- Create: `ReceiptLens/Views/ScanDetailView.swift`

- [ ] **Step 1: Write the detail screen**

```swift
import SwiftUI
import UIKit

struct ScanDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let scan: ReceiptScan

    @State private var image: UIImage?
    @State private var showingZoom = false
    @State private var showingAskAgain = false
    @State private var showingDeleteConfirm = false

    // Ask-again working copies (don't mutate the stored scan).
    @State private var askMode: AnalysisMode = .receipt
    @State private var askPrompt = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                imageHeader
                HStack(spacing: 8) {
                    Label(scan.mode.label, systemImage: scan.mode.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scan.mode.tint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(scan.mode.tint.opacity(0.15)))
                    Text("· \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(scan.output)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(scan.mode.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: scan.output) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = scan.output } label: {
                        Label("Copy output", systemImage: "doc.on.doc")
                    }
                    Button { startAskAgain() } label: { Label("Ask again", systemImage: "arrow.uturn.left") }
                    Divider()
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fullScreenCover(isPresented: $showingZoom) {
            if let image { ZoomableImageView(image: image) }
        }
        .sheet(isPresented: $showingAskAgain) {
            if let image {
                AnalyzeSheet(image: image, startWithInput: true,
                             mode: $askMode, customPrompt: $askPrompt)
            }
        }
        .confirmationDialog("Delete this scan?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                appState.deleteScan(scan)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: scan.id) {
            image = await appState.imageStore.loadImage(at: appState.imageURL(for: scan))
        }
    }

    @ViewBuilder private var imageHeader: some View {
        if let image {
            Image(uiImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onTapGesture { showingZoom = true }
        } else {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: 240)
                .overlay { ProgressView() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            ShareLink(item: scan.output) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).clipShape(Capsule())
            Button { startAskAgain() } label: {
                Label("Ask again", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered).clipShape(Capsule())
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
    }

    private func startAskAgain() {
        askMode = scan.mode
        askPrompt = ""
        showingAskAgain = true
    }
}
```

- [ ] **Step 2: Confirm against spec**

- Image taps → full-screen zoom. ✓
- Mode pill (tinted) + timestamp; monospaced selectable output card. ✓
- ⋯ menu: Share / Copy / Ask again / Delete (destructive, confirmation). ✓
- Bottom row: Share (prominent) + Ask again (bordered). ✓
- Ask again preselects the scan's mode, blank prompt, opens `AnalyzeSheet` in input phase; a successful run inserts a NEW scan via `appState.analyze`, leaving the original intact. ✓

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/ScanDetailView.swift
git commit -m "Add standalone ScanDetailView with zoom, share, ask-again, delete"
```

---

## Task 11: HistoryView rewrite (buckets + search + thumbnails)

**Files:**
- Modify: `ReceiptLens/Views/HistoryView.swift` (full replacement; inline `ScanDetailView` removed — now its own file from Task 10)

- [ ] **Step 1: Replace the file**

```swift
import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    private var sections: [(bucket: HistoryBucket, scans: [ReceiptScan])] {
        let filtered = HistorySectioning.filter(appState.scans, query: query)
        return HistorySectioning.grouped(filtered)
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sections, id: \.bucket) { section in
                            Section(section.bucket.rawValue) {
                                ForEach(section.scans) { scan in
                                    NavigationLink {
                                        ScanDetailView(scan: scan)
                                    } label: {
                                        ScanRow(scan: scan)
                                    }
                                }
                                .onDelete { offsets in delete(in: section.scans, at: offsets) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: "Search scans")
                }
            }
            .navigationTitle("History")
            .toolbar { if !appState.scans.isEmpty { EditButton() } }
        }
    }

    private func delete(in scans: [ReceiptScan], at offsets: IndexSet) {
        for index in offsets { appState.deleteScan(scans[index]) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No scans yet").font(.title2.weight(.semibold))
            Text("Tap Scan to capture one.")
                .font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanRow: View {
    @EnvironmentObject private var appState: AppState
    let scan: ReceiptScan
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color(.secondarySystemGroupedBackground))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: scan.mode.systemImage).foregroundStyle(scan.mode.tint)
                    Text(scan.mode.label).font(.headline)
                    Text("· \(scan.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(scan.output)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .task(id: scan.imageFilename) {
            thumb = await ThumbnailCache.shared.thumbnail(for: appState.imageURL(for: scan))
        }
    }
}
```

- [ ] **Step 2: Confirm against spec**

- Inset-grouped list, date buckets, `.searchable` live filter on output + mode. ✓
- 56×56 rounded thumbnail (lazy, cached), title = glyph + mode + time, subtitle = first 2 lines. ✓
- Swipe-to-delete (`.onDelete`) and Edit-button multi-select both work; delete maps section-relative offsets to the right scan via id. ✓
- Empty state matches spec. ✓
- `ScanDetailView` is now resolved from Task 10's file (no longer defined here). ✓

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/HistoryView.swift
git commit -m "Rewrite HistoryView with date buckets, search, and thumbnail rows"
```

---

## Task 12: SettingsView

**Files:**
- Create: `ReceiptLens/Views/SettingsView.swift`

- [ ] **Step 1: Write the settings sheet**

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultMode") private var defaultModeRaw = AnalysisMode.receipt.rawValue

    @State private var showingDeleteModel = false
    @State private var showingClearHistory = false

    private var defaultMode: Binding<AnalysisMode> {
        Binding(
            get: { AnalysisMode(rawValue: defaultModeRaw) ?? .receipt },
            set: { defaultModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                Section("Defaults") {
                    Picker("Default mode", selection: defaultMode) {
                        ForEach(AnalysisMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Storage") {
                    LabeledContent("Scans", value: "\(appState.scans.count)")
                    Button("Clear all history", role: .destructive) { showingClearHistory = true }
                        .disabled(appState.scans.isEmpty)
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Engine", value: "llama.cpp")
                    LabeledContent("Context", value: "\(EngineConfig.nCtx)")
                    LabeledContent("Max output", value: "\(EngineConfig.nPredict) tokens")
                    Link(destination: URL(string: "https://github.com")!) {
                        LabeledContent("GitHub") { Image(systemName: "arrow.up.right") }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete model files?", isPresented: $showingDeleteModel, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to download MiniCPM-V 4.6 again (~1.6 GB) before scanning.")
            }
            .confirmationDialog("Clear all history?", isPresented: $showingClearHistory, titleVisibility: .visible) {
                Button("Clear all", role: .destructive) { appState.clearAllScans() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every saved scan and its image. This cannot be undone.")
            }
        }
    }

    @ViewBuilder private var modelSection: some View {
        Section("Model") {
            HStack {
                statusRow
                Spacer()
            }
            switch appState.modelStore.state {
            case .downloading:
                EmptyView()
            default:
                Button(appState.modelStore.files.isReady ? "Re-download model" : "Download model") {
                    Task { await appState.modelStore.downloadAll() }
                }
            }
            if appState.modelStore.files.isReady {
                Button("Delete model and start over", role: .destructive) { showingDeleteModel = true }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch appState.modelStore.state {
        case .ready:
            Label { Text("Ready").font(.headline) + Text("\nMiniCPM-V 4.6 · ~1.6 GB").font(.caption).foregroundStyle(.secondary) }
            icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        case .downloading(let name, let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) \(Int(progress * 100))%").font(.subheadline)
                ProgressView(value: progress)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .idle:
            Label("Download to start", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private func deleteModel() {
        try? FileManager.default.removeItem(at: appState.modelStore.files.llm)
        try? FileManager.default.removeItem(at: appState.modelStore.files.mmproj)
        appState.modelStore.refresh()
    }
}
```

- [ ] **Step 2: Confirm against spec**

- Form / inset-grouped. Model status adapts (ready / downloading bar / idle / failed). ✓
- Re-download (or Download when missing) + Delete model (destructive, confirmation). ✓
- Default mode `Picker` bound to `@AppStorage("defaultMode")` — same key the Scan screen reads. ✓
- Storage: scan count + Clear all history (destructive, confirmation → `clearAllScans()`). ✓
- About: version (from bundle), engine, context, max output (from `EngineConfig`), GitHub `Link`. ✓
- Note: the GitHub URL is a placeholder `https://github.com`; the implementer should swap in the real repo URL when known. Flagged in self-review.

- [ ] **Step 3: Commit**

```bash
git add ReceiptLens/Views/SettingsView.swift
git commit -m "Add SettingsView sheet (model, defaults, storage, about)"
```

---

## Task 13: RootView two-tab + remove ModelSetupView

**Files:**
- Modify: `ReceiptLens/Views/RootView.swift`
- Delete: `ReceiptLens/Views/ModelSetupView.swift`

- [ ] **Step 1: Replace RootView**

```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ScannerView()
                .tabItem { Label("Scan", systemImage: "viewfinder") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
    }
}
```

- [ ] **Step 2: Delete the old Model tab screen**

```bash
git rm ReceiptLens/Views/ModelSetupView.swift
```

- [ ] **Step 3: Confirm**

Two tabs (Scan, History). Settings is reached via the gear in ScannerView (Task 8). No remaining reference to `ModelSetupView` (it was only used in the old RootView). ✓

- [ ] **Step 4: Commit**

```bash
git add ReceiptLens/Views/RootView.swift
git commit -m "Reduce to two tabs and remove ModelSetupView (now Settings sheet)"
```

---

## Task 14: Build verification via GitHub Actions + final review

**Files:** none (CI + review)

This is the compile/link gate for the whole plan. Requires pushing the branch, which triggers `workflow_dispatch` build — **get explicit user approval before pushing** (Git Safety).

- [ ] **Step 1: Local sanity scan**

Confirm no dangling references to removed symbols:

```bash
git -C . grep -n "ModelSetupView\|panelStyle\|StatusPill" -- ReceiptLens || echo "clean"
```

Expected: `clean` (or only matches inside deleted/rewritten files that no longer exist).

- [ ] **Step 2: Push the feature branch (after approval)**

```bash
git push -u origin HEAD
```

- [ ] **Step 3: Trigger and watch the unsigned build**

```bash
gh workflow run "Build unsigned iOS IPA"
gh run watch "$(gh run list --workflow='Build unsigned iOS IPA' --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: build succeeds (compiles + links on Xcode 16 / macos-15).

- [ ] **Step 4: If the build fails**

Read the failing step's log, fix the specific compile error in the offending Swift file, commit, push, re-run. Do not skip the build or disable steps.

- [ ] **Step 5: Download the IPA for sideload**

```bash
gh run download "$(gh run list --workflow='Build unsigned iOS IPA' --limit 1 --json databaseId -q '.[0].databaseId')"
```

Hand off to the developer to sideload and visually verify each screen on device (Scan empty/has-image/analyzing, History buckets+search, Detail+zoom, Settings).

---

## Self-Review

**1. Spec coverage**

| Spec item | Task |
|---|---|
| Section 1 foundation (accent, materials, spacing, radii, motion) | Applied across Tasks 6–13 |
| Two tabs + Settings gear | 8 (gear), 13 (tabs) |
| Scan State A empty | 8 |
| Scan State B has-image | 8 |
| Scan State C analyzing sheet (Stop, Share/Ask-again/Done, error) | 7 |
| History buckets + search + thumbnails | 3, 2, 11 |
| Scan detail + zoom + ⋯ menu | 9, 10 |
| Ask-again reuse | 7 (input phase) + 10 (entry) |
| Settings (model/defaults/storage/about) | 12 |
| Model-not-ready guard alert | 8 |
| Default mode persistence | 5 (key), 8 (read), 12 (set) |
| Clear-all history | 5, 12 |
| Multi-select + swipe delete | 11 |
| Accessibility labels / updatesFrequently | 6, 7, 8 |

No spec section is unmapped.

**2. Placeholder scan**

- The only intentional placeholder is the GitHub URL in Task 12 (`https://github.com`), flagged in that task's Step 2 for the implementer to replace with the real repo URL. No "TBD"/"add error handling"/"similar to Task N" placeholders elsewhere; every code step shows full code.
- Spec's `.accessibilityLiveRegion(.polite)` was intentionally dropped — that modifier does not exist in SwiftUI. Replaced with `.accessibilityAddTraits(.updatesFrequently)` (Task 7), which is the correct API for streaming regions.

**3. Type consistency**

- `AnalysisMode.tint` / `.label` / `.systemImage` — defined in Task 1, used in 6, 7, 10, 11, 12. ✓
- `AnalyzeSheet(image:startWithInput:mode:customPrompt:)` — defined Task 7, called identically in 8 and 10. ✓
- `appState.deleteScan(_:)` / `clearAllScans()` — defined Task 5, used in 10, 11, 12. ✓
- `ThumbnailCache.shared.thumbnail(for:)` / `.remove(filename:)` — defined Task 2, used in 5, 11. ✓
- `HistorySectioning.filter` / `.grouped` / `HistoryBucket` — defined Task 3, used in 11. ✓
- `MiniCPMEngine.analyze` return-on-cancel — Task 4 keeps the existing signature; AppState (unchanged path) still inserts the scan. ✓
- `@AppStorage("defaultMode")` key string identical in Tasks 5 (doc note), 8, 12. ✓

No signature mismatches found.
