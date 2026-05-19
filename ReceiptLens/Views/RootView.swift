import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ScannerView()
                .tabItem {
                    Label("Scan", systemImage: "viewfinder")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            ModelSetupView()
                .tabItem {
                    Label("Model", systemImage: "shippingbox")
                }
        }
        .tint(Color(red: 0.078, green: 0.443, blue: 0.373))
    }
}

