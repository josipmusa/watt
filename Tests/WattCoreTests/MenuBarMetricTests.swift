import Foundation
import Testing
@testable import WattCore

struct MenuBarMetricTests {
    @Test func selectsSupportedClaudeWindows() {
        let snapshot = HarnessUsageSnapshot.demo(for: .claude)

        #expect(MenuBarMetric.session.limit(in: snapshot)?.id == "session")
        #expect(MenuBarMetric.weekly.limit(in: snapshot)?.id == "weekly")
        #expect(MenuBarMetric.fable.limit(in: snapshot)?.id == "fable")
        #expect(MenuBarMetric.session.name(for: .claude) == "Session")
        #expect(MenuBarMetric.weekly.name(for: .claude) == "Weekly")
        #expect(MenuBarMetric.fable.name(for: .claude) == "Fable")
    }

    @Test func selectsSupportedCodexWindows() {
        let snapshot = HarnessUsageSnapshot.demo(for: .codex)

        #expect(MenuBarMetric.session.limit(in: snapshot) == nil)
        #expect(MenuBarMetric.weekly.limit(in: snapshot)?.id == "weekly")
        #expect(MenuBarMetric.fable.limit(in: snapshot) == nil)
        #expect(MenuBarMetric.weekly.name(for: .codex) == "Weekly")
    }

    @Test func doesNotSubstituteAnUnrelatedWindow() {
        let snapshot = HarnessUsageSnapshot(
            harness: .claude,
            limits: [UsageLimit(id: "fable", name: "Fable", percentage: 18, resetDate: nil)],
            fetchedAt: .now
        )

        #expect(MenuBarMetric.session.limit(in: snapshot) == nil)
        #expect(MenuBarMetric.weekly.limit(in: snapshot) == nil)
        #expect(MenuBarMetric.fable.limit(in: snapshot)?.id == "fable")
    }
}
