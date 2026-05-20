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
