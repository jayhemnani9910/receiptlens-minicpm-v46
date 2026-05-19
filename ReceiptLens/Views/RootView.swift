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
    }
}

