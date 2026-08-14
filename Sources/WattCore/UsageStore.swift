import AppKit
import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    private static let cacheVersion = 2

    @Published public private(set) var states: [HarnessUsageState] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var refreshingHarnesses: Set<HarnessKind> = []
    @Published public private(set) var hasCompletedDiscovery = false

    private let providers: [any HarnessUsageProviding]
    private var policies: [HarnessKind: RefreshPolicy]
    private var nextScheduledRefresh: [HarnessKind: Date] = [:]
    private var cooldownUntil: [HarnessKind: Date] = [:]
    private var scheduleTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastManualRefresh: Date = .distantPast
    private let now: @Sendable () -> Date
    private let jitteredDelay: @Sendable (TimeInterval) -> TimeInterval
    private let cacheURL: URL?

    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Watt", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    public init(
        providers: [any HarnessUsageProviding],
        policies: [HarnessKind: RefreshPolicy] = [.claude: .claude, .codex: .codex],
        now: @escaping @Sendable () -> Date = { .now },
        jitteredDelay: @escaping @Sendable (TimeInterval) -> TimeInterval = {
            $0 * Double.random(in: 0.9 ... 1.1)
        },
        cacheURL: URL? = nil
    ) {
        self.providers = providers
        self.policies = policies
        self.now = now
        self.jitteredDelay = jitteredDelay
        self.cacheURL = cacheURL
        if let cacheURL, let cache = Self.loadCache(from: cacheURL) {
            states = cache.entries.map(\.state)
                .sorted { $0.harness.sortOrder < $1.harness.sortOrder }
            nextScheduledRefresh = Dictionary(uniqueKeysWithValues: cache.entries.compactMap { entry in
                entry.nextScheduledRefresh.map { (entry.state.harness, $0) }
            })
            cooldownUntil = Dictionary(uniqueKeysWithValues: cache.entries.compactMap { entry in
                entry.cooldownUntil.map { (entry.state.harness, $0) }
            })
            hasCompletedDiscovery = !states.isEmpty
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: .wake) }
        }
    }

    deinit {
        scheduleTask?.cancel()
        refreshTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    public enum RefreshReason: Sendable {
        case launch, popover, wake, manual, scheduled
    }

    public var snapshots: [HarnessUsageSnapshot] {
        states.compactMap(\.snapshot)
    }

    public func isRefreshing(_ harness: HarnessKind) -> Bool {
        refreshingHarnesses.contains(harness)
    }

    public func isDataStale(for state: HarnessUsageState) -> Bool {
        guard let fetchedAt = state.snapshot?.fetchedAt else { return false }
        let staleAfter = max(180, (policies[state.harness]?.successDelay ?? 60) * 2)
        return now().timeIntervalSince(fetchedAt) > staleAfter
    }

    /// A failed refresh does not make a recent, usable snapshot stale. Surface
    /// the failure once its provider-specific freshness window has elapsed.
    public func warningMessage(for state: HarnessUsageState) -> String? {
        if state.snapshot == nil {
            return state.failure?.message
        }
        guard isDataStale(for: state) else { return nil }
        return state.failure?.message ?? "\(state.harness.name) usage data may be stale."
    }

    public func start() {
        refresh(reason: .launch)
    }

    public func refresh(reason: RefreshReason) {
        let currentDate = now()
        if reason == .manual {
            guard currentDate.timeIntervalSince(lastManualRefresh) >= 30 else { return }
        }
        guard refreshTask == nil else { return }

        let selectedProviders = providers.filter { provider in
            switch reason {
            case .launch:
                return (nextScheduledRefresh[provider.harness] ?? .distantPast) <= currentDate
                    && (cooldownUntil[provider.harness] ?? .distantPast) <= currentDate
            case .manual:
                return (cooldownUntil[provider.harness] ?? .distantPast) <= currentDate
            case .popover, .wake, .scheduled:
                return (nextScheduledRefresh[provider.harness] ?? .distantPast) <= currentDate
                    && (cooldownUntil[provider.harness] ?? .distantPast) <= currentDate
            }
        }
        guard !selectedProviders.isEmpty else {
            scheduleNextRefresh()
            return
        }
        if reason == .manual {
            lastManualRefresh = currentDate
        }

        isRefreshing = true
        refreshingHarnesses = Set(selectedProviders.map(\.harness))
        refreshTask = Task { [weak self, selectedProviders] in
            let outcomes = await withTaskGroup(of: ProviderOutcome.self, returning: [ProviderOutcome].self) { group in
                for provider in selectedProviders {
                    group.addTask {
                        do {
                            return .success(try await provider.fetchUsage())
                        } catch {
                            let typed = error as? any HarnessUsageProviderError
                            let failure = HarnessFailure(
                                message: typed?.errorDescription ?? error.localizedDescription,
                                shouldBackOff: typed?.shouldBackOff ?? true,
                                isNotConfigured: typed?.isNotConfigured ?? false,
                                retryAfter: typed?.retryAfter
                            )
                            return .failure(provider.harness, failure)
                        }
                    }
                }

                var results: [ProviderOutcome] = []
                for await outcome in group { results.append(outcome) }
                return results
            }
            guard !Task.isCancelled else { return }
            self?.finish(outcomes)
        }
    }

    private func finish(_ outcomes: [ProviderOutcome]) {
        var next = Dictionary(uniqueKeysWithValues: states.map { ($0.harness, $0) })
        let currentDate = now()

        for outcome in outcomes {
            switch outcome {
            case let .success(snapshot):
                next[snapshot.harness] = HarnessUsageState(harness: snapshot.harness, snapshot: snapshot)
                recordSuccess(for: snapshot.harness, at: currentDate)
            case let .failure(harness, failure):
                if failure.isNotConfigured {
                    next.removeValue(forKey: harness)
                } else {
                    var state = next[harness] ?? HarnessUsageState(harness: harness)
                    state.failure = failure
                    next[harness] = state
                }
                recordFailure(failure, for: harness, at: currentDate)
            }
        }

        states = next.values.sorted { $0.harness.sortOrder < $1.harness.sortOrder }
        hasCompletedDiscovery = true
        refreshTask = nil
        isRefreshing = false
        refreshingHarnesses = []

        saveCache()
        scheduleNextRefresh()
    }

    private func recordSuccess(for harness: HarnessKind, at date: Date) {
        var policy = policies[harness] ?? .standard
        policy.recordSuccess()
        policies[harness] = policy
        cooldownUntil.removeValue(forKey: harness)
        nextScheduledRefresh[harness] = date.addingTimeInterval(policy.nextDelay)
    }

    private func recordFailure(_ failure: HarnessFailure, for harness: HarnessKind, at date: Date) {
        var policy = policies[harness] ?? .standard
        if failure.shouldBackOff {
            policy.recordFailure(shouldBackOff: true)
            let delay = max(failure.retryAfter ?? 0, jitteredDelay(policy.nextDelay))
            let nextDate = date.addingTimeInterval(delay)
            cooldownUntil[harness] = nextDate
            nextScheduledRefresh[harness] = nextDate
        } else {
            policy.recordSuccess()
            cooldownUntil.removeValue(forKey: harness)
            nextScheduledRefresh[harness] = date.addingTimeInterval(policy.nextDelay)
        }
        policies[harness] = policy
    }

    private func scheduleNextRefresh() {
        scheduleTask?.cancel()
        let configuredHarnesses = Set(providers.map(\.harness))
        let nextDate = nextScheduledRefresh
            .filter { configuredHarnesses.contains($0.key) }
            .map(\.value)
            .min()
        guard let nextDate else { return }
        let delay = max(0.1, nextDate.timeIntervalSince(now()))
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh(reason: .scheduled)
        }
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let entries = states.map { state in
            CachedProviderState(
                state: state,
                nextScheduledRefresh: nextScheduledRefresh[state.harness],
                cooldownUntil: cooldownUntil[state.harness]
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(UsageCache(
                version: Self.cacheVersion,
                entries: entries
            )).write(to: cacheURL, options: .atomic)
        } catch {
            // The cache is an optimization; usage fetching must continue if it cannot be written.
        }
    }

    private static func loadCache(from url: URL) -> UsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cache = try? JSONDecoder().decode(UsageCache.self, from: data),
              cache.version == cacheVersion else { return nil }
        return cache
    }
}

private struct UsageCache: Codable {
    let version: Int
    let entries: [CachedProviderState]
}

private struct CachedProviderState: Codable {
    let state: HarnessUsageState
    let nextScheduledRefresh: Date?
    let cooldownUntil: Date?
}

private enum ProviderOutcome: Sendable {
    case success(HarnessUsageSnapshot)
    case failure(HarnessKind, HarnessFailure)
}
