# ReceiptLens UI Redesign — Design Spec

**Date:** 2026-05-19 (resumed and finalized 2026-05-20)
**Status:** All three sections approved. Open items resolved (see below). Ready for the implementation plan (writing-plans).

---

## Context

The post-audit ReceiptLens app works correctly on a real iPhone, but the UI feels dated. The user described it as "iPhone 4 or 5 display" — meaning cramped vertical stacks of small boxes, sub-standard use of screen real estate, generic system-default look without intent.

Scope of redesign: full visual rebuild of all screens AND addition of three new features (share/export, history search, re-run with different prompt). The underlying engine, model, and bridge layers stay as they are after the audit fixes.

## Decisions locked

| Question | Answer |
|---|---|
| Visual personality | **iOS-native premium** (Apple HIG, system fonts, system materials, single accent) |
| Mode hierarchy | **All three modes equal** (Receipt, Document, Screen) |
| Navigation structure | **2 tabs (Scan, History) + Settings as a gear-icon sheet** from Scan |
| New features | Share/export, Search History, Re-run with different prompt ("Ask again") |
| App name | **Keep ReceiptLens** |
| Accent color | **Keep current teal-green** (`AccentColor.colorset`, R 0.078 / G 0.443 / B 0.373) — easy to change later |
| Scan layout direction | **Hero + bottom sheet** — image fills the top; mode chips and prompt below; Analyze opens a bottom sheet with streaming output |
| App icon | Keep existing for this redesign; revisit after implementation |
| History delete | System Edit button (multi-select) + swipe-to-delete; both come from `List` |
| Thumbnail caching | Lazy load via `ImageFileStore`, backed by an in-memory `NSCache` keyed by filename |

---

## Section 1 — Foundation (APPROVED)

**Typography:** SF Pro (system). Large Title for screen titles, Title2 for section headers, Body for content, Caption for metadata.

**Color system:** Single accent from `AccentColor.colorset`. Everything else from system semantic colors (`.systemGroupedBackground`, `.systemBackground`, `.secondarySystemGroupedBackground`, automatic separators). Full dark-mode support comes free.

**Materials:** `.regularMaterial` for floating chip rows and bottom CTA pill backgrounds. `.ultraThinMaterial` for the hero-image gradient overlay (so chips read against any photo).

**Spacing scale:** 8 / 16 / 24 / 32. Cards = 16 padding, screens = 24 inset, hero sections = 32 between.

**Corner radius:** 12 (content cards), 16 (sheets), 20 (hero image), 999 (pill / capsule).

**Tab bar:** Two items:
1. Scan — SF Symbol `viewfinder`
2. History — SF Symbol `clock.arrow.circlepath`

Settings = gear icon in Scan's nav bar (top right), opens as a `.sheet`. Model tab is dissolved into Settings.

**Motion:** System spring defaults. Mode chips scale 0.96 on press. Bottom sheet uses `presentationDetents([.medium, .large])`. Token streaming text uses `.animation(nil)` so the result card doesn't reflow on every token.

---

## Section 2 — Scan screen (APPROVED)

Three states.

### State A: Empty (no image picked)

```
ReceiptLens                       ⚙
┌──────────────────────────────────┐
│         📄                       │
│      Add an image                │  ← Title2
│   Receipt, document,             │  ← Body, .secondary
│     or screenshot                │
└──────────────────────────────────┘

[Receipt] [Document] [Screen]       ← chips dimmed, untappable

┌──────────────────────────────────┐
│  📷 Camera        🖼 Photos      │  ← pinned bottom, equal-width pills
└──────────────────────────────────┘
```

- Hero card: rounded rect, `.secondarySystemGroupedBackground` fill, occupies upper ~55% of available height.
- Mode chips visible but dimmed (`.opacity(0.5)`) so they're discoverable.
- Bottom pills via `.safeAreaInset(edge: .bottom)`. Camera = `.borderedProminent` (accent), Photos = `.bordered`.

### State B: Has image, idle

```
ReceiptLens                       ⚙
┌──────────────────────────────────┐
│                                  │
│       [the image]            ┌─┐ │
│                              │↻│ │  ← Retake icon-only pill,
│                              └─┘ │     top-right, .thinMaterial bg
└──────────────────────────────────┘

[Receipt] [Document] [Screen]       ← active; selected = accent fill

Custom prompt                  ▶   ← collapsed disclosure

┌──────────────────────────────────┐
│           Analyze  ✨            │  ← single pinned pill, accent
└──────────────────────────────────┘
```

- Image card: corner radius 20, `.scaledToFit`, max ~60% screen height.
- Retake pill is icon-only over a `.thinMaterial` background overlay at the top-right corner of the image card.
- Mode chips: capsule. Selected = accent fill. Others = `.regularMaterial` fill. Exactly one selected at all times.
- Disclosure expands to show a `TextEditor` (multi-line, ~3 visible lines, system background). Footer caption: *"Leave blank to use the built-in `<mode>` prompt."*
- Analyze button = sole bottom-pinned control. Full width, prominent, accent.

### State C: Analyzing (bottom sheet open)

Scan screen stays visible above sheet, slightly dimmed.

```
━━━                                ← drag indicator
Reading…              [Stop ⏹]    ← title + Stop right-aligned

Walmart
Date: 2026-05-19
Subtotal: $32.00
Tax: $2.27
Total: $34.27
Payment: Visa ****1234
█                                  ← caret while streaming
```

- Sheet: `presentationDetents([.medium, .large])`, `presentationDragIndicator(.visible)`.
- `interactiveDismissDisabled(true)` while generating. Stop is the only exit during stream.
- Header shows "Reading…" with animated `…` until EOG, then becomes `<mode> · just now`.
- After EOG, action row appears at bottom of sheet:
  ```
  [Share]  [Ask again]  [Done]
  ```
- **Share** = `ShareLink` over the output text (long-press for Copy).
- **Ask again** = sheet content morphs into mini mode picker + prompt field + image thumbnail + Analyze pill. Submitting runs a NEW analysis on the same image; creates a NEW scan entry.
- **Done** = dismisses sheet, Scan screen resets to State A. (The scan persists the moment generation completed.)

### Errors during analysis

Sheet content swaps to error layout: SF Symbol `exclamationmark.triangle` (red), Title2 "Couldn't read this", Body with `MTMDError.localizedDescription`, buttons `[Try again]` and `[Done]`.

---

## Section 3 — History / Detail / Settings (APPROVED)

### History screen

- Large title "History", system Edit button on the right, `.searchable` for filter.
- `InsetGroupedListStyle`. Sections by date bucket: **Today**, **Yesterday**, **Previous 7 days**, **Earlier**.
- Row: 56×56 rounded thumbnail (corner 8) on the left; title = mode SF Symbol + mode name + `·` + time; subtitle = first 2 lines of `output` (`lineLimit(2)`).
- `.searchable(text:)` filters live by output text or mode name.
- `ForEach + .onDelete` already wired up post-audit. Edit button enables multi-select delete.
- Empty state: SF Symbol `clock.arrow.circlepath`, Title2 "No scans yet", Body "Tap Scan to capture one".

### Scan detail screen (tap a history row)

```
< History                ⋯
┌──────────────────────────────────┐
│        [the image]               │  ← tap → full-screen viewer
└──────────────────────────────────┘

🧾 Receipt   · Today, 4:32 PM        ← mode pill + timestamp

┌──────────────────────────────────┐
│  Walmart                          │
│  Date: 2026-05-19                 │  ← .body.monospaced(),
│  Subtotal: $32.00                 │     .textSelection(.enabled)
│  Tax: $2.27                       │
│  Total: $34.27                    │
└──────────────────────────────────┘

[Share]      [Ask again]             ← pinned bottom row
```

- `⋯` menu (system context menu): Share, Copy output, Ask again, Delete (destructive).
- Tap image → `.fullScreenCover` with a `ScrollView` containing an `Image` with `magnification` for pinch-to-zoom.
- Mode pill: capsule, accent tint, SF Symbol + name.
- Output card: `.body.monospaced()`, `.textSelection(.enabled)`, `.secondarySystemGroupedBackground`.
- Bottom action row: Share = `.borderedProminent` (accent), Ask again = `.bordered`.

### Ask Again flow

Reuses Section 2's analyzing sheet pattern.
1. Tap *Ask again* → bottom sheet appears with: image thumbnail (small, top-left), mode chips (current pre-selected), prompt `TextEditor` (current pre-filled), Analyze pill.
2. Tap *Analyze* → content swaps to the "Reading…" streaming UI from State C.
3. EOG → action row appears. NEW `ReceiptScan` is created. Both original and new visible in History.

### Settings sheet (gear in Scan)

```
                Settings      Done
MODEL
┌──────────────────────────────────┐
│  ✓ Ready                          │  ← or ProgressView + % if downloading
│   MiniCPM-V 4.6 · 1.6 GB         │
└──────────────────────────────────┘
[Re-download model]
[Delete model and start over]      ← destructive, confirmation dialog

DEFAULTS
Default mode             Receipt >  ← Picker

STORAGE
Scans                       12 >    ← total count
[Clear all history]                 ← destructive

ABOUT
Version                       0.1
Engine                  llama.cpp
Context                      4096   ← from EngineConfig
Max output            768 tokens
GitHub                          >   ← opens Safari
```

- `Form` with `InsetGroupedListStyle`.
- Model status row: if downloaded → checkmark + filename + size; if downloading → ProgressView + percent + bytes; if missing → exclamation + "Download to start" (and Re-download becomes "Download").
- Re-download and Delete model use `.confirmationDialog`.
- Default mode persists via `@AppStorage("defaultMode")`. Scan screen reads on appear.
- Clear all history: confirmation dialog → deletes all scans and their image files (uses existing `AppState.deleteScans` + image cleanup).
- GitHub row uses `Link` to open repo URL in Safari.

### Model-not-ready guard

If user taps Analyze with `modelStore.files.isReady == false`:
- Alert: title "Model not downloaded yet", body "Download MiniCPM-V 4.6 (~1.6 GB) in Settings to use this feature.", buttons *Open Settings* (presents the sheet) and *Cancel*.

### Accessibility

- Every interactive element gets a clear `.accessibilityLabel`.
- Mode chips use `accessibilityValue` for selected state.
- Streaming output region uses `.accessibilityAddTraits(.updatesFrequently)` and `.accessibilityLiveRegion(.polite)` so VoiceOver reads new tokens as they arrive.
- Dynamic Type respected throughout. `ViewThatFits` for the hero/mode-chip area to handle larger text sizes gracefully.

---

## Open items — resolved

1. **Section 3** — approved as written.
2. **App icon** — keep current for this redesign; revisit after implementation.
3. **History delete** — keep both the system Edit button (multi-select) and swipe-to-delete. Both fall out of `List` + `.onDelete` + `EditButton` for near-zero cost, and match iOS conventions.
4. **Thumbnail caching** — lazy load each row's thumbnail through `ImageFileStore`, backed by an in-memory `NSCache<NSString, UIImage>` keyed by filename, so scrolling doesn't re-decode. No eager thumb generation; revisit only if a large history scrolls poorly.

## Self-review notes

- **Default mode source of truth:** `@AppStorage("defaultMode")` is read by both Settings (Picker) and Scan (initial chip selection). `AnalysisMode` must be `RawRepresentable` by a stable `String` so `@AppStorage` can store it.
- **`AnalysisMode.tintColor`:** Section 1 locks a single accent. The chip "selected = accent fill" rule stands; `tintColor` per mode is only for the small mode glyph/pill identity in History and Detail, not for chip selection. Kept subtle to avoid contradicting the single-accent rule.
- **Ask-again reuse:** Section 2 State C and Section 3 Ask-again share one `AnalyzeSheet`. The sheet takes an input (image + preselected mode + prefilled prompt) and a completion that inserts a new `ReceiptScan`. One component, two entry points.
- **No placeholders or TBDs remain.** Every screen has empty/loading/error states defined.

## Next steps

1. Invoke **writing-plans** to produce the per-file implementation plan.
2. Implement against that plan.

---

## Source files most affected by this redesign

Reference for the implementation phase.

| File | Change shape |
|---|---|
| `ReceiptLens/Views/RootView.swift` | Drop Model tab, add Settings sheet presentation state |
| `ReceiptLens/Views/ScannerView.swift` | Full rewrite: hero + chips + Analyze + bottom sheet for streaming |
| `ReceiptLens/Views/HistoryView.swift` | Date bucketing, search, thumbnail rows |
| `ReceiptLens/Views/ModelSetupView.swift` | Rename/repurpose as `SettingsView`, restructure as Form sections |
| `ReceiptLens/Views/CameraPicker.swift` | No change |
| `ReceiptLens/AppState.swift` | Add `defaultMode` from `@AppStorage`, `clearAllScans()`, maybe thumbnail helper |
| `ReceiptLens/Models/AnalysisMode.swift` | Add `tintColor` and richer SF Symbols for visual identity |
| `ReceiptLens/Models/EngineConfig.swift` | Possibly expose more values for the About section |
| **NEW** `ReceiptLens/Views/ScanDetailView.swift` (currently inside HistoryView) | Pulled into own file for the new layout |
| **NEW** `ReceiptLens/Views/AnalyzeSheet.swift` | The bottom sheet (shared between Scan analyze + Detail ask-again) |
| **NEW** `ReceiptLens/Views/ModeChip.swift` | The reusable mode capsule |
| **NEW** `ReceiptLens/Views/SettingsView.swift` | The settings sheet content |
| **NEW** `ReceiptLens/Views/ZoomableImageView.swift` | Full-screen image viewer with pinch-to-zoom |
