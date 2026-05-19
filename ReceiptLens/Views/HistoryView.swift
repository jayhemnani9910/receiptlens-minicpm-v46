import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(appState.scans) { scan in
                            NavigationLink {
                                ScanDetailView(scan: scan)
                            } label: {
                                ScanRow(scan: scan)
                            }
                        }
                        .onDelete(perform: appState.deleteScans)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !appState.scans.isEmpty {
                    EditButton()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No scans yet")
                .font(.headline)
            Text("Completed analyses appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanRow: View {
    let scan: ReceiptScan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(scan.mode.rawValue, systemImage: scan.mode.systemImage)
                .font(.headline)
            Text(scan.output)
                .font(.subheadline)
                .lineLimit(3)
                .foregroundStyle(.secondary)
            Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ScanDetailView: View {
    @EnvironmentObject private var appState: AppState
    let scan: ReceiptScan

    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(height: 240)
                        .overlay { ProgressView() }
                }

                Text(scan.output)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(scan.mode.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scan.id) {
            image = await appState.imageStore.loadImage(at: appState.imageURL(for: scan))
        }
    }
}
