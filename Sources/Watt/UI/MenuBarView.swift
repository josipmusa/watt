import AppKit
import ServiceManagement
import SwiftUI
import WattCore

struct MenuBarView: View {
    @ObservedObject var store: UsageStore
    @Binding var claudeMenuBarMetric: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(height: 43)

            Divider().opacity(0.42)

            usage
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider().opacity(0.55)

            controls
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
        }
        .frame(width: 330)
        .background(.background)
        .onAppear {
            store.refresh(reason: .popover)
            refreshLoginItemStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Watt")
                .font(.system(size: 14, weight: .semibold))
            Spacer()

            Button {
                store.refresh(reason: .manual)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh usage")
        }
    }

    @ViewBuilder
    private var usage: some View {
        if store.states.isEmpty {
            emptyState
        } else {
            VStack(spacing: 14) {
                ForEach(Array(store.states.enumerated()), id: \.element.id) { index, state in
                    if index > 0 {
                        Divider().opacity(0.42)
                    }
                    providerSection(state)
                }
            }
        }
    }

    private func providerSection(_ state: HarnessUsageState) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 7) {
                HarnessMark(harness: state.harness)
                if state.harness == .claude {
                    claudeMetricPicker
                } else {
                    Text("Weekly")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let warning = store.warningMessage(for: state) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(warning)
                }
                Text(UsageFormatting.updatedText(
                    fetchedAt: state.snapshot?.fetchedAt,
                    isRefreshing: store.isRefreshing(state.harness)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if let snapshot = state.snapshot {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(displayedLimits(in: snapshot)) { limit in
                        VStack(spacing: 6) {
                            UsageRing(limit: limit, harness: state.harness, size: 58, lineWidth: 4)
                            Text(limit.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(shortReset(for: limit))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .help(UsageFormatting.resetText(for: limit))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text(state.failure?.message ?? "Loading \(state.harness.name) usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: store.hasCompletedDiscovery ? "bolt.slash" : "bolt.badge.clock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.hasCompletedDiscovery ? "No supported harnesses found" : "Looking for Claude and Codex…")
                .font(.system(size: 12.5, weight: .medium))
            if store.hasCompletedDiscovery {
                Text("Sign in with Claude Code or Codex, then refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 92)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    Label("Launch at Login", systemImage: "power")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                if let loginItemMessage {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(loginItemMessage)
                }

                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .font(.system(size: 12.5))
    }

    private var claudeMetricPicker: some View {
        let selected = MenuBarMetric(rawValue: claudeMenuBarMetric) ?? .weekly

        return Menu {
            ForEach(MenuBarMetric.allCases) { metric in
                Button {
                    claudeMenuBarMetric = metric.rawValue
                } label: {
                    if metric == selected {
                        Label(metric.name(for: .claude), systemImage: "checkmark")
                    } else {
                        Text(metric.name(for: .claude))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "menubar.rectangle")
                Text(selected.name(for: .claude))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Metric shown in the menu bar")
    }

    private func refreshLoginItemStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginItemMessage = SMAppService.mainApp.status == .requiresApproval
            ? "Allow Watt in System Settings › General › Login Items."
            : nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItemStatus()
        } catch {
            refreshLoginItemStatus()
            loginItemMessage = error.localizedDescription
        }
    }

    private func shortReset(for limit: UsageLimit) -> String {
        guard let date = limit.resetDate else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: .now)
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(relative) · \(time)"
    }

    private func displayedLimits(in snapshot: HarnessUsageSnapshot) -> [UsageLimit] {
        guard snapshot.harness == .codex else { return snapshot.limits }
        return MenuBarMetric.weekly.limit(in: snapshot).map { [$0] } ?? []
    }
}
