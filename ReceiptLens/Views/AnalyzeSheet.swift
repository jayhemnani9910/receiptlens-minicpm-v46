import SwiftUI

struct AnalyzeSheet: View {
    /// The image to analyze (already in memory). For Scan this is the just-picked
    /// photo; for Ask-again it is the loaded detail image.
    let image: UIImage
    /// When true, the sheet opens on an input step (mode + prompt) before running.
    /// Scan passes false (it runs immediately); Ask-again passes true.
    let startWithInput: Bool
    @Binding var mode: AnalysisMode
    @Binding var customPrompt: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase
    @State private var promptExpanded = false

    enum Phase { case input, running, done, failed }

    init(image: UIImage, startWithInput: Bool,
         mode: Binding<AnalysisMode>, customPrompt: Binding<String>) {
        self.image = image
        self.startWithInput = startWithInput
        self._mode = mode
        self._customPrompt = customPrompt
        self._phase = State(initialValue: startWithInput ? .input : .running)
    }

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .input:    inputContent
            case .running:  runningContent
            case .done:     resultContent(error: false)
            case .failed:   resultContent(error: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .running)
        .task(id: phaseRunToken) {
            if phase == .running { await run() }
        }
        .onChange(of: appState.engine.state) { newState in
            switch newState {
            case .ready where phase == .running: phase = .done
            case .failed where phase == .running: phase = .failed
            default: break
            }
        }
    }

    // Re-trigger `.task` only when we (re)enter running.
    private var phaseRunToken: Int { phase == .running ? runCounter : -1 }
    @State private var runCounter = 0

    private func run() async {
        await appState.analyze(image: image, mode: mode, customPrompt: customPrompt)
    }

    // MARK: Input (Ask-again)

    private var inputContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Ask again").font(.title2.weight(.semibold))
                Spacer()
            }
            ModeChipRow(selection: $mode)
            promptDisclosure
            Button {
                runCounter += 1
                phase = .running
            } label: {
                Label("Analyze", systemImage: "sparkles")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            Spacer(minLength: 0)
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
    }

    // MARK: Running

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reading\(dots)").font(.title2.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    appState.engine.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            ScrollView {
                Text(appState.engine.output.isEmpty ? " " : appState.engine.output)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(nil, value: appState.engine.output)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onAppear { animateDots() }
    }

    @State private var dots = ""
    private func animateDots() {
        guard phase == .running else { return }
        let states = ["", ".", "..", "..."]
        Task { @MainActor in
            var i = 0
            while phase == .running {
                dots = states[i % states.count]; i += 1
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            dots = ""
        }
    }

    // MARK: Done / Failed

    private func resultContent(error: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.red)
                    Text("Couldn't read this").font(.title2.weight(.semibold))
                    Text(appState.engine.state.title)
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Label(mode.label, systemImage: mode.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode.tint)
                    Text("· just now").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView {
                    Text(appState.engine.output)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 12) {
                if error {
                    Button { runCounter += 1; phase = .running } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule())
                } else {
                    ShareLink(item: appState.engine.output) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule())

                    Button {
                        customPrompt = ""
                        promptExpanded = false
                        phase = .input
                    } label: {
                        Label("Ask again", systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).clipShape(Capsule())
                }

                Button("Done") { dismiss() }
                    .frame(minHeight: 44)
            }
        }
    }
}
