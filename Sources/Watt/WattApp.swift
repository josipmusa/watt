import AppKit
import SwiftUI
import WattCore

@main
struct WattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: UsageStore
    @AppStorage("menuBar.claude.metric") private var claudeMenuBarMetric = MenuBarMetric.weekly.rawValue

    init() {
        ProcessInfo.processInfo.disableAutomaticTermination("Watt keeps its menu-bar item available")
        ProcessInfo.processInfo.disableSuddenTermination()

        let providers: [any HarnessUsageProviding]
        let cacheURL: URL?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let demoMode = ProcessInfo.processInfo.environment["WATT_DEMO"]
        if arguments.contains("--live-codex-only") {
            providers = [CodexAppServerUsageProvider()]
            cacheURL = nil
        } else if demoMode != nil || arguments.contains(where: { $0.hasPrefix("--demo") }) {
            cacheURL = nil
            if demoMode == "codex" || arguments.contains("--demo-codex-only") {
                providers = [MockHarnessUsageProvider(harness: .codex)]
            } else if demoMode == "claude" || arguments.contains("--demo-claude-only") {
                providers = [MockHarnessUsageProvider(harness: .claude)]
            } else {
                providers = [
                    MockHarnessUsageProvider(harness: .claude),
                    MockHarnessUsageProvider(harness: .codex),
                ]
            }
        } else {
            providers = Self.liveProviders
            cacheURL = UsageStore.defaultCacheURL
        }
        #else
        providers = Self.liveProviders
        cacheURL = UsageStore.defaultCacheURL
        #endif

        let store = UsageStore(providers: providers, cacheURL: cacheURL)
        _store = StateObject(wrappedValue: store)

        Task { @MainActor in
            store.start()
            try? await Task.sleep(for: .milliseconds(300))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-popover-preview") {
                DebugPopoverPresenter.shared.show(store: store)
            }
            #endif
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                store: store,
                claudeMenuBarMetric: $claudeMenuBarMetric
            )
        } label: {
            MenuBarGlyph(
                states: store.states,
                claudeSelection: MenuBarMetric(rawValue: claudeMenuBarMetric) ?? .weekly
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static var liveProviders: [any HarnessUsageProviding] {
        [
            ClaudeOAuthUsageProvider(credentials: ClaudeCodeCredentialProvider()),
            CodexAppServerUsageProvider(),
        ]
    }
}

#if DEBUG
@MainActor
private final class DebugPopoverPresenter {
    static let shared = DebugPopoverPresenter()
    private var panel: NSPanel?

    func show(store: UsageStore) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: MenuBarView(
            store: store,
            claudeMenuBarMetric: .constant(MenuBarMetric.weekly.rawValue)
        ))
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
#endif

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
