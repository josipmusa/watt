import SwiftUI
import WattCore

enum WattPalette {
    /// Claude's familiar warm clay, kept deliberately muted so the HUD stays calm.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// A quiet blue-teal that stays legible in both light and dark vibrancy.
    static let codex = Color(red: 0.310, green: 0.561, blue: 0.616)

    static func accent(for harness: HarnessKind) -> Color {
        switch harness {
        case .claude: claude
        case .codex: codex
        }
    }
}

struct UsageRing: View {
    let limit: UsageLimit
    let harness: HarnessKind
    var size: CGFloat = 58
    var lineWidth: CGFloat = 4
    var showsValue = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var displayedProgress = 0.0

    private var progress: Double { (limit.percentage ?? 0) / 100 }

    private var color: Color {
        guard let percentage = limit.percentage else { return .secondary }
        if percentage >= 95 { return Color(nsColor: .systemRed) }
        if percentage >= 80 { return Color(nsColor: .systemOrange) }
        return WattPalette.accent(for: harness)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.10), lineWidth: lineWidth)

            if limit.percentage != nil {
                Circle()
                    .trim(from: 0, to: displayedProgress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .rotationEffect(.degrees(-90))

                if differentiateWithoutColor, let percentage = limit.percentage, percentage >= 80 {
                    Circle()
                        .trim(from: max(0, displayedProgress - 0.035), to: displayedProgress)
                        .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }

            if showsValue {
                Text(limit.roundedPercentage.map { "\($0)%" } ?? "—")
                    .font(.system(size: max(10, size * 0.22), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(limit.percentage == nil ? .secondary : .primary)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onAppear { updateProgress(animated: false) }
        .onChange(of: progress) { _, _ in updateProgress(animated: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.name)
        .accessibilityValue(limit.roundedPercentage.map { "\($0) percent used" } ?? "Unavailable")
    }

    private func updateProgress(animated: Bool) {
        guard animated, !reduceMotion else {
            displayedProgress = progress
            return
        }
        withAnimation(.smooth(duration: 0.48)) { displayedProgress = progress }
    }
}

struct HarnessMark: View {
    let harness: HarnessKind
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: harness == .claude ? "sparkles" : "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WattPalette.accent(for: harness))
                .frame(width: 14)
            if showsName {
                Text(harness.name)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
