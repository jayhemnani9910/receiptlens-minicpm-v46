import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Group {
                if appState.scans.isEmpty {
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
                } else {
                    List(appState.scans) { scan in
                        NavigationLink {
                            ScanDetailView(scan: scan)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(scan.mode.rawValue, systemImage: scan.mode.systemImage)
                                    .font(.headline)
                                Text(scan.output)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}

struct ScanDetailView: View {
    let scan: ReceiptScan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = UIImage(contentsOfFile: scan.imageURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    }
}
