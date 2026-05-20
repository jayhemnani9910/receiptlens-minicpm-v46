import SwiftUI

struct ModeChip: View {
    let mode: AnalysisMode
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Label(mode.label, systemImage: mode.systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .scaleEffect(pressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel(mode.label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }
}

struct ModeChipRow: View {
    @Binding var selection: AnalysisMode
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalysisMode.allCases) { mode in
                ModeChip(mode: mode, isSelected: selection == mode, isEnabled: isEnabled) {
                    selection = mode
                }
            }
        }
    }
}
