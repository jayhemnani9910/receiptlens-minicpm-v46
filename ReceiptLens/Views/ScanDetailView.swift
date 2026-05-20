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
