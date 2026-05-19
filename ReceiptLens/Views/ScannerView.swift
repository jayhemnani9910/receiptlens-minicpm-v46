import PhotosUI
import SwiftUI
import UIKit

struct ScannerView: View {
    @EnvironmentObject private var appState: AppState

    @State private var mode: AnalysisMode = .receipt
    @State private var selectedImage: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var customPrompt = ""
    @State private var showingCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    modePicker
                    imagePanel
                    promptPanel
                    runButton
                    outputPanel
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ReceiptLens")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingCamera) {
                CameraPicker(image: $selectedImage)
            }
            .onChange(of: selectedPhoto) { item in
                Task {
                    selectedImage = try? await item?.loadUIImage()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Offline reader")
                    .font(.title2.weight(.semibold))
                Text(appState.modelStore.state.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: appState.engine.state.title)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AnalysisMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var imagePanel: some View {
        VStack(spacing: 12) {
            if let selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.08))
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Add an image")
                        .font(.headline)
                    Text("Use camera or pick a receipt, document, or screenshot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(minHeight: 240)
            }

            HStack(spacing: 10) {
                Button {
                    showingCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .panelStyle()
    }

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $customPrompt)
                .frame(minHeight: 92)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Leave blank to use the built-in \(mode.rawValue.lowercased()) prompt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .panelStyle()
    }

    private var runButton: some View {
        Button {
            guard let selectedImage else { return }
            Task {
                await appState.analyze(image: selectedImage, mode: mode, customPrompt: customPrompt)
            }
        } label: {
            Label("Analyze", systemImage: "sparkles")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedImage == nil || !appState.modelStore.files.isReady || appState.engine.state == .running)
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                if appState.engine.state == .running {
                    ProgressView()
                }
            }

            Text(appState.engine.output.isEmpty ? "No result yet." : appState.engine.output)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .panelStyle()
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.06))
            }
    }
}
