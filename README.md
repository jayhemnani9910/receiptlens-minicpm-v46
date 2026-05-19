# ReceiptLens

Offline iPhone prototype for MiniCPM-V 4.6 receipt, document, and screenshot reading.

## What is included

- SwiftUI iOS app shell.
- Model downloader for MiniCPM-V 4.6 GGUF files.
- Native `llama.cpp` / `mtmd` bridge copied from the official OpenBMB iOS demo.
- Camera/photo picker flow.
- Receipt, document, and screen-analysis prompt modes.

## Build on Mac

```bash
brew install xcodegen
cd ReceiptLens
xcodegen generate
open ReceiptLens.xcodeproj
```

In Xcode:

1. Select your personal team under Signing & Capabilities.
2. Pick your iPhone 14 Pro as the run destination.
3. Run the app.
4. Open the Model tab and download the two model files.

This Linux machine cannot compile/sign iOS apps because Xcode is macOS-only.

## Free No-Mac Build Path

You can build an unsigned IPA with GitHub Actions macOS runners, then sign and install it from Ubuntu with iLoader/SideStore.

1. Push this `ReceiptLens/` folder as the root of a public GitHub repo.
2. Run the `Build unsigned iOS IPA` workflow.
3. Download the `ReceiptLens-unsigned-ipa` artifact.
4. On Ubuntu, install iLoader and `usbmuxd`.
5. Use iLoader/SideStore with your Apple ID to sign and install the IPA.

Limits:

- Free Apple ID sideloaded apps need periodic refresh.
- This is for personal testing, not App Store/TestFlight distribution.
- If the GitHub repo is private, macOS runner minutes may count against your free quota.

## Model Files

The app downloads these to the app documents directory:

- `MiniCPM-V-4_6-Q4_K_M.gguf`
- `MiniCPM-V-4_6-mmproj-master-f16.gguf`

Total download is roughly 1.6 GB. Keep the app open during the first download.

Once downloaded, the model files live locally inside the iPhone app sandbox. The analysis path is offline unless you delete the app or its data.
