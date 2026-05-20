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
