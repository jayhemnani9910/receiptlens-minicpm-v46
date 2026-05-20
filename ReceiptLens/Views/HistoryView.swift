import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    private var sections: [(bucket: HistoryBucket, scans: [ReceiptScan])] {
        let filtered = HistorySectioning.filter(appState.scans, query: query)
        return HistorySectioning.grouped(filtered)
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sections, id: \.bucket) { section in
                            Section(section.bucket.rawValue) {
                                ForEach(section.scans) { scan in
                                    NavigationLink {
                                        ScanDetailView(scan: scan)
                                    } label: {
                                        ScanRow(scan: scan)
                                    }
                                }
                                .onDelete { offsets in delete(in: section.scans, at: offsets) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: "Search scans")
                }
            }
            .navigationTitle("History")
            .toolbar { if !appState.scans.isEmpty { EditButton() } }
        }
    }

    private func delete(in scans: [ReceiptScan], at offsets: IndexSet) {
        for index in offsets { appState.deleteScan(scans[index]) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No scans yet").font(.title2.weight(.semibold))
            Text("Tap Scan to capture one.")
                .font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanRow: View {
    @EnvironmentObject private var appState: AppState
    let scan: ReceiptScan
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color(.secondarySystemGroupedBackground))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: scan.mode.systemImage).foregroundStyle(scan.mode.tint)
                    Text(scan.mode.label).font(.headline)
                    Text("· \(scan.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(scan.output)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .task(id: scan.imageFilename) {
            thumb = await ThumbnailCache.shared.thumbnail(for: appState.imageURL(for: scan))
        }
    }
}
