import Foundation
import Testing
@testable import WattCore

@MainActor
struct UsageStoreTests {
    @Test func keepsConfiguredProvidersAndSortsThemConsistently() async {
        let store = UsageStore(providers: [
            StubProvider(harness: .codex, result: .success(.demo(for: .codex))),
            StubProvider(harness: .claude, result: .success(.demo(for: .claude))),
        ])

        store.start()
        while store.isRefreshing { await Task.yield() }

        #expect(store.states.map(\.harness) == [.claude, .codex])
        #expect(store.snapshots.count == 2)
        #expect(store.hasCompletedDiscovery)
    }

    @Test func omitsNotConfiguredProviderWithoutHidingHealthyProvider() async {
        let store = UsageStore(providers: [
            StubProvider(harness: .claude, result: .failure(.notConfigured)),
            StubProvider(harness: .codex, result: .success(.demo(for: .codex))),
        ])

        store.start()
        while store.isRefreshing { await Task.yield() }

        #expect(store.states.map(\.harness) == [.codex])
        #expect(store.states.first?.snapshot?.limits.count == 2)
    }

    @Test func preservesLastGoodSnapshotWhenOneProviderRefreshFails() async {
        let claude = SequencedProvider(
            harness: .claude,
            results: [.success(.demo(for: .claude)), .failure(.temporary)]
        )
        let store = UsageStore(providers: [claude])

        store.start()
        while store.isRefreshing { await Task.yield() }
        store.refresh(reason: .manual)
        while store.isRefreshing { await Task.yield() }

        #expect(store.states.first?.snapshot != nil)
        #expect(store.states.first?.failure?.message == "Temporarily unavailable")
        #expect(store.warningMessage(for: store.states[0]) == nil)
    }

    @Test func providerWithoutUsableDataWarnsImmediately() async {
        let store = UsageStore(providers: [
            StubProvider(harness: .claude, result: .failure(.temporary)),
        ])

        store.start()
        while store.isRefreshing { await Task.yield() }

        #expect(store.states[0].snapshot == nil)
        #expect(store.warningMessage(for: store.states[0]) == "Temporarily unavailable")
    }

    @Test func recentSnapshotDoesNotWarnAfterFailedRefresh() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let recent = HarnessUsageSnapshot(
            harness: .claude,
            limits: HarnessUsageSnapshot.demo(for: .claude).limits,
            fetchedAt: clock.now
        )
        let claude = SequencedProvider(
            harness: .claude,
            results: [.success(recent), .failure(.temporary)]
        )
        let store = UsageStore(
            providers: [claude],
            policies: [.claude: RefreshPolicy(successDelay: 300, failureDelays: [300])],
            now: { clock.now },
            jitteredDelay: { $0 }
        )

        store.start()
        while store.isRefreshing { await Task.yield() }
        clock.advance(by: 40)
        store.refresh(reason: .manual)
        while store.isRefreshing { await Task.yield() }

        #expect(store.states[0].failure != nil)
        #expect(store.warningMessage(for: store.states[0]) == nil)

        clock.advance(by: 561)
        #expect(store.warningMessage(for: store.states[0]) == "Temporarily unavailable")
    }

    @Test func healthyCodexDoesNotResetClaudeBackoff() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let claude = SequencedProvider(
            harness: .claude,
            results: [.failure(.temporary), .success(.demo(for: .claude))]
        )
        let codex = SequencedProvider(
            harness: .codex,
            results: [.success(.demo(for: .codex)), .success(.demo(for: .codex))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            policies: [
                .claude: RefreshPolicy(successDelay: 300, failureDelays: [900]),
                .codex: RefreshPolicy(successDelay: 60, failureDelays: [120]),
            ],
            now: { clock.now },
            jitteredDelay: { $0 }
        )

        store.start()
        while store.isRefreshing { await Task.yield() }
        clock.advance(by: 60)
        store.refresh(reason: .scheduled)
        while store.isRefreshing { await Task.yield() }

        #expect(await claude.fetchCount == 1)
        #expect(await codex.fetchCount == 2)
        #expect(store.states.first(where: { $0.harness == .claude })?.failure != nil)
    }

    @Test func popoverDoesNotRefreshFreshProviders() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let claude = SequencedProvider(
            harness: .claude,
            results: [.success(.demo(for: .claude)), .success(.demo(for: .claude))]
        )
        let store = UsageStore(
            providers: [claude],
            now: { clock.now },
            jitteredDelay: { $0 }
        )

        store.start()
        while store.isRefreshing { await Task.yield() }
        store.refresh(reason: .popover)

        #expect(await claude.fetchCount == 1)
        #expect(!store.isRefreshing)
    }

    @Test func retryAfterCooldownBlocksManualRefresh() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let claude = SequencedProvider(
            harness: .claude,
            results: [.failure(.rateLimited(1_200)), .success(.demo(for: .claude))]
        )
        let store = UsageStore(
            providers: [claude],
            policies: [.claude: RefreshPolicy(successDelay: 300, failureDelays: [300])],
            now: { clock.now },
            jitteredDelay: { $0 }
        )

        store.start()
        while store.isRefreshing { await Task.yield() }
        clock.advance(by: 60)
        store.refresh(reason: .manual)

        #expect(await claude.fetchCount == 1)
        #expect(!store.isRefreshing)
    }

    @Test func retryAfterCooldownSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watt-tests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("usage-cache.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        var firstStore: UsageStore? = UsageStore(
            providers: [SequencedProvider(harness: .claude, results: [.failure(.rateLimited(1_200))])],
            policies: [.claude: RefreshPolicy(successDelay: 300, failureDelays: [300])],
            now: { clock.now },
            jitteredDelay: { $0 },
            cacheURL: cacheURL
        )
        firstStore?.start()
        while firstStore?.isRefreshing == true { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        firstStore = nil

        let relaunchedProvider = SequencedProvider(
            harness: .claude,
            results: [.success(.demo(for: .claude))]
        )
        let relaunchedStore = UsageStore(
            providers: [relaunchedProvider],
            policies: [.claude: RefreshPolicy(successDelay: 300, failureDelays: [300])],
            now: { clock.now },
            jitteredDelay: { $0 },
            cacheURL: cacheURL
        )
        relaunchedStore.start()

        #expect(await relaunchedProvider.fetchCount == 0)
        #expect(relaunchedStore.states.first?.failure?.retryAfter == 1_200)
        #expect(!relaunchedStore.isRefreshing)
    }
}

private enum StubFailure: HarnessUsageProviderError {
    case notConfigured
    case temporary
    case rateLimited(TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not configured"
        case .temporary: "Temporarily unavailable"
        case .rateLimited: "Rate limited"
        }
    }

    var shouldBackOff: Bool {
        switch self {
        case .temporary, .rateLimited: true
        case .notConfigured: false
        }
    }
    var isNotConfigured: Bool {
        if case .notConfigured = self { return true }
        return false
    }
    var retryAfter: TimeInterval? {
        if case let .rateLimited(delay) = self { return delay }
        return nil
    }
}

private actor StubProvider: HarnessUsageProviding {
    nonisolated let harness: HarnessKind
    let result: Result<HarnessUsageSnapshot, StubFailure>

    init(harness: HarnessKind, result: Result<HarnessUsageSnapshot, StubFailure>) {
        self.harness = harness
        self.result = result
    }

    func fetchUsage() async throws -> HarnessUsageSnapshot {
        try result.get()
    }
}

private actor SequencedProvider: HarnessUsageProviding {
    nonisolated let harness: HarnessKind
    private var results: [Result<HarnessUsageSnapshot, StubFailure>]
    private(set) var fetchCount = 0

    init(harness: HarnessKind, results: [Result<HarnessUsageSnapshot, StubFailure>]) {
        self.harness = harness
        self.results = results
    }

    func fetchUsage() async throws -> HarnessUsageSnapshot {
        fetchCount += 1
        return try results.removeFirst().get()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}
