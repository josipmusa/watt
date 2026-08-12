import Foundation

public enum HarnessKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex

    public var id: Self { self }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .claude: 0
        case .codex: 1
        }
    }
}

public struct UsageLimit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let percentage: Double?
    public let resetDate: Date?

    public init(id: String, name: String, percentage: Double?, resetDate: Date?) {
        self.id = id
        self.name = name
        self.percentage = percentage.map { min(max($0, 0), 100) }
        self.resetDate = resetDate
    }

    public var roundedPercentage: Int? {
        percentage.map { Int($0.rounded()) }
    }
}

public struct HarnessUsageSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let harness: HarnessKind
    public let limits: [UsageLimit]
    public let fetchedAt: Date

    public var id: HarnessKind { harness }

    public init(harness: HarnessKind, limits: [UsageLimit], fetchedAt: Date) {
        self.harness = harness
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    public static func demo(for harness: HarnessKind, at date: Date = .now) -> HarnessUsageSnapshot {
        switch harness {
        case .claude:
            HarnessUsageSnapshot(
                harness: .claude,
                limits: [
                    UsageLimit(id: "session", name: "Session", percentage: 34, resetDate: date.addingTimeInterval(2.3 * 3600)),
                    UsageLimit(id: "weekly", name: "Weekly", percentage: 62, resetDate: date.addingTimeInterval(3.2 * 86_400)),
                    UsageLimit(id: "fable", name: "Fable", percentage: 18, resetDate: date.addingTimeInterval(4.6 * 86_400)),
                ],
                fetchedAt: date
            )
        case .codex:
            HarnessUsageSnapshot(
                harness: .codex,
                limits: [
                    UsageLimit(id: "primary", name: "5 hour", percentage: 23, resetDate: date.addingTimeInterval(1.6 * 3600)),
                    UsageLimit(id: "secondary", name: "Weekly", percentage: 47, resetDate: date.addingTimeInterval(3.2 * 86_400)),
                ],
                fetchedAt: date
            )
        }
    }
}

public struct HarnessFailure: Codable, Equatable, Sendable {
    public let message: String
    public let shouldBackOff: Bool
    public let isNotConfigured: Bool
    public let retryAfter: TimeInterval?

    public init(
        message: String,
        shouldBackOff: Bool,
        isNotConfigured: Bool,
        retryAfter: TimeInterval? = nil
    ) {
        self.message = message
        self.shouldBackOff = shouldBackOff
        self.isNotConfigured = isNotConfigured
        self.retryAfter = retryAfter
    }
}

public protocol HarnessUsageProviderError: LocalizedError, Sendable {
    var shouldBackOff: Bool { get }
    var isNotConfigured: Bool { get }
    var retryAfter: TimeInterval? { get }
}

public extension HarnessUsageProviderError {
    var retryAfter: TimeInterval? { nil }
}

public protocol HarnessUsageProviding: Sendable {
    var harness: HarnessKind { get }
    func fetchUsage() async throws -> HarnessUsageSnapshot
}

public struct HarnessUsageState: Codable, Equatable, Sendable, Identifiable {
    public let harness: HarnessKind
    public var snapshot: HarnessUsageSnapshot?
    public var failure: HarnessFailure?

    public var id: HarnessKind { harness }

    public init(harness: HarnessKind, snapshot: HarnessUsageSnapshot? = nil, failure: HarnessFailure? = nil) {
        self.harness = harness
        self.snapshot = snapshot
        self.failure = failure
    }
}

public actor MockHarnessUsageProvider: HarnessUsageProviding {
    public nonisolated let harness: HarnessKind
    private let snapshot: HarnessUsageSnapshot
    private let delay: Duration

    public init(harness: HarnessKind, delay: Duration = .milliseconds(180)) {
        self.harness = harness
        snapshot = .demo(for: harness)
        self.delay = delay
    }

    public func fetchUsage() async throws -> HarnessUsageSnapshot {
        try await Task.sleep(for: delay)
        return snapshot
    }
}
