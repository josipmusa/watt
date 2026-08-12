import AppKit
import ServiceManagement
import SwiftUI
import WattCore

struct MenuBarView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var hud: FloatingHUDController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 15)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().opacity(0.42)

            usage
                .padding(.horizontal, 15)
                .padding(.vertical, 12)

            Divider().opacity(0.55)

            controls
                .padding(9)
        }
        .frame(width: 330)
        .background(.background)
        .onAppear {
            store.refresh(reason: .popover)
            refreshLoginItemStatus()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Watt")
                .font(.headline)

            Spacer()

            if store.hasStaleData {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help(store.combinedErrorMessage ?? "Usage data may be stale")
            }

            Text(UsageFormatting.updatedText(fetchedAt: store.latestFetchedAt, isRefreshing: store.isRefreshing))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var usage: some View {
        if store.states.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 10) {
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

            if let snapshot = state.snapshot {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(snapshot.limits) { limit in
                        VStack(spacing: 5) {
                            UsageRing(limit: limit, harness: state.harness, size: 58, lineWidth: 4)
                            Text(limit.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(shortReset(for: limit))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
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
                Toggle(isOn: Binding(get: { hud.isVisible }, set: { hud.setVisible($0) })) {
                    Label("Keep Visible", systemImage: "pin")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button {
                    store.refresh(reason: .manual)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh usage")

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }

            HStack(spacing: 6) {
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
            }
        }
        .font(.system(size: 12.5))
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
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
