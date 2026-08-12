import SwiftUI
import WattCore

struct MenuBarGlyph: View {
    let snapshots: [HarnessUsageSnapshot]

    private var progress: Double? {
        snapshots.flatMap(\.limits).compactMap(\.percentage).max().map { $0 / 100 }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(progress == nil ? 0.58 : 0.28), lineWidth: 1.45)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.035, progress))
                    .stroke(
                        Color.primary,
                        style: StrokeStyle(lineWidth: 1.65, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Image(systemName: "bolt.fill")
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: 15, height: 15)
        .accessibilityLabel("Watt")
    }
}
