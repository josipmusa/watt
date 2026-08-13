import SwiftUI
import WattCore

struct MenuBarGlyph: View {
    let states: [HarnessUsageState]
    let claudeSelection: MenuBarMetric

    var body: some View {
        statusText
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .help(detailText)
            .accessibilityLabel(detailText)
    }

    /// A single Text lets MenuBarExtra measure changing provider content without
    /// clipping. macOS renders status-item text monochromatically, so the menu
    /// bar stays clean while the popover carries the provider colors and marks.
    private var statusText: Text {
        guard !states.isEmpty else { return Text("⚡︎ Watt") }

        let sharesWeeklyMetric = states.count > 1
            && states.allSatisfy { selection(for: $0.harness) == .weekly }
        var text = Text("⚡︎  ")
        for (index, state) in states.enumerated() {
            if index > 0 { text = text + Text("  ·  ") }
            let metric = selection(for: state.harness)
            let value = selectedLimit(for: state)?.roundedPercentage.map { "\($0)%" } ?? "Unavailable"
            text = text
                + Text(state.harness.name).bold()
                + Text(sharesWeeklyMetric ? " \(value)" : " \(metric.name(for: state.harness)) \(value)")
        }
        return text
    }

    private func selectedLimit(for state: HarnessUsageState) -> UsageLimit? {
        state.snapshot.flatMap { selection(for: state.harness).limit(in: $0) }
    }

    private func selection(for harness: HarnessKind) -> MenuBarMetric {
        harness == .claude ? claudeSelection : .weekly
    }

    private var detailText: String {
        let metrics = states.map { state in
            let selection = selection(for: state.harness)
            let value = selectedLimit(for: state)?.roundedPercentage.map { "\($0)%" } ?? "Unavailable"
            return "\(state.harness.name) \(selection.name(for: state.harness)) · \(value)"
        }
        return (["Watt"] + metrics).joined(separator: "\n")
    }
}
