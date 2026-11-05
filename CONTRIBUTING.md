# Contributing

Thanks for taking a look. Bug reports, fixes and small features are all welcome.

## Setup

You need a Mac with Xcode and XcodeGen.

```bash
brew install xcodegen
git clone https://github.com/jayhemnani9910/receiptlens-minicpm-v46.git
cd receiptlens-minicpm-v46
xcodegen generate
open ReceiptLens.xcodeproj
```

`ReceiptLens.xcodeproj` is generated from `project.yml` and is not checked in. If you add a file or change a build setting, change `project.yml` and run `xcodegen generate` again.

To try a real scan you need an iPhone and the model files (about 1.6 GB, downloaded from the Model tab). The simulator is fine for UI work and tests.

## Tests

```bash
xcodebuild -project ReceiptLens.xcodeproj -scheme ReceiptLens -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Use any simulator you have installed. CI runs the same tests plus an unsigned device build on every push and pull request.

## Style

- Match the code around you. There is no linter yet.
- Keep the C bridge in `ReceiptLens/NativeBridge/Bridge/` on the public llama.cpp API (`llama.h`, `mtmd.h`, `mtmd-helper.h`).
- Do not commit model files, build output or signing settings with your team ID.

## Pull requests

- Branch off `main` and open the PR against `main`.
- One change per PR, with a short note on what it does and how you checked it.
- Add or update a test when you change prompts, models or saved data.

## Bugs

Open an issue with the steps, what you expected, what happened, your iPhone model and iOS version, and the commit you built. If the model failed to load or crashed, include the message from the Xcode console.

I try to reply to issues within a few days.
