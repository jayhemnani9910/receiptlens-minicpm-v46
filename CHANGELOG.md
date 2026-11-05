# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Nothing is tagged yet. This is everything from the first commit on 2026-05-19.

### Added
- SwiftUI iPhone app with Scan, History and Model tabs.
- Receipt, Document and Screen modes, each with its own prompt, plus a custom prompt field.
- Download of the MiniCPM-V 4.6 GGUF model and vision projector from Hugging Face.
- Native C bridge over llama.cpp `mtmd`, based on the OpenBMB iOS demo.
- Scans saved to `scans.json` with their images. Swipe to delete in History.
- Stop button while the model is writing.
- GitHub Actions workflow that builds an unsigned IPA.
- MIT license and third-party notices for the OpenBMB bridge and llama.cpp.
- Unit tests for prompts, saved scans and model URLs.
- CI workflow that builds for device and runs the tests on every push and pull request.
- Contributing guide, issue templates and a pull request template.

### Fixed
- The image now goes inside the chat-format user turn, as the model expects.
- `reset()` waits for in-flight bridge calls before freeing the context.
- A failed model load no longer leaves the engine stuck in "initializing".
- Live output and download progress now update the UI.
- Analyze is disabled while the model is loading or running.
- Removed the sleeps and polling in the token loop.

### Changed
- Camera and photo picking use UIKit pickers (`UIImagePickerController` and `PHPickerViewController`).
- Dropped the unused CoreAudioTypes link.
