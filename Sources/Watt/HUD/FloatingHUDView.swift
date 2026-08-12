import SwiftUI
import WattCore

struct FloatingHUDView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var controller: FloatingHUDController

    var body: some View {
        ZStack {
            HUDBackground()

            if controller.isExpanded {
                expanded
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                compact
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            if !controller.isExpanded { controller.setExpanded(true) }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.05), value: controller.isExpanded)
    }

    private var compact: some View {
        Group {
            if store.states.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.clock")
                        .foregroundStyle(.secondary)
                    Text(store.hasCompletedDiscovery ? "No supported harnesses found" : "Looking for harnesses…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.states.enumerated()), id: \.element.id) { index, state in
                        if index > 0 {
                            Divider()
                                .opacity(0.36)
                                .padding(.horizontal, 12)
                        }
                        compactRow(state)
                    }
                }
            }
        }
        .accessibilityHint("Click to show usage details")
    }

    private func compactRow(_ state: HarnessUsageState) -> some View {
        HStack(spacing: 10) {
            HarnessMark(harness: state.harness)
                .frame(width: 66, alignment: .leading)

            Spacer(minLength: 0)

            if let limits = state.snapshot?.limits {
                HStack(spacing: 9) {
                    ForEach(limits) { limit in
                        UsageRing(limit: limit, harness: state.harness, size: 42, lineWidth: 3.2)
                    }
                }
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .help(state.failure?.message ?? "Usage unavailable")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            Button { controller.setExpanded(false) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.secondary)
                    Text("Usage")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse HUD")
            .padding(.horizontal, 15)
            .frame(height: 34)

            Divider().opacity(0.36)

            if store.states.isEmpty {
                Text(store.hasCompletedDiscovery ? "No supported harnesses found" : "Looking for Claude and Codex…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 74)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.states.enumerated()), id: \.element.id) { index, state in
                        if index > 0 {
                            Divider().opacity(0.36).padding(.horizontal, 12)
                        }
                        expandedSection(state)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { controller.setExpanded(false) }
                .accessibilityHint("Click to collapse")
            }

            Divider().opacity(0.45).padding(.horizontal, 12)

            HStack(spacing: 12) {
                if store.hasStaleData {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(store.combinedErrorMessage ?? "Usage data may be stale")
                }

                Text(UsageFormatting.updatedText(fetchedAt: store.latestFetchedAt, isRefreshing: store.isRefreshing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Button { store.refresh(reason: .manual) } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("Refresh usage")

                Button { controller.setVisible(false) } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.plain)
                .help("Hide floating HUD")
            }
            .padding(.horizontal, 15)
            .frame(height: 44)
        }
    }

    private func expandedSection(_ state: HarnessUsageState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HarnessMark(harness: state.harness)
                Spacer()
                if state.failure != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(state.failure?.message ?? "Usage unavailable")
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 30)

            if let limits = state.snapshot?.limits {
                ForEach(limits) { limit in
                    HStack(spacing: 11) {
                        UsageRing(limit: limit, harness: state.harness, size: 42, lineWidth: 3.2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(limit.name)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(UsageFormatting.resetText(for: limit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 48)
                }
            } else {
                Text(state.failure?.message ?? "Usage unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            }
        }
    }
}
