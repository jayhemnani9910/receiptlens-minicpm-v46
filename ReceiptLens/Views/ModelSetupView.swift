import SwiftUI

struct ModelSetupView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(appState.modelStore.state.title, systemImage: statusIcon)

                    Button {
                        Task {
                            await appState.modelStore.downloadAll()
                        }
                    } label: {
                        Label("Download MiniCPM-V 4.6", systemImage: "arrow.down.circle")
                    }
                    .disabled(appState.modelStore.files.isReady || isDownloading)
                }

                Section("Files") {
                    fileRow("LLM", url: appState.modelStore.files.llm)
                    fileRow("Vision", url: appState.modelStore.files.mmproj)
                }

                Section("Runtime") {
                    LabeledContent("Mode", value: "Fully offline")
                    LabeledContent("Engine", value: "llama.cpp")
                    LabeledContent("Context", value: "4096")
                    LabeledContent("Device", value: "iPhone 14 Pro target")
                }
            }
            .navigationTitle("Model")
        }
    }

    private var isDownloading: Bool {
        if case .downloading = appState.modelStore.state {
            return true
        }
        return false
    }

    private var statusIcon: String {
        appState.modelStore.files.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle"
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: FileManager.default.fileExists(atPath: url.path) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(FileManager.default.fileExists(atPath: url.path) ? .green : .secondary)
        }
    }
}

