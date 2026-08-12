import Foundation

public struct RefreshPolicy: Equatable, Sendable {
    public static let standard = RefreshPolicy(delays: [60, 120, 300])
    public static let claude = RefreshPolicy(
        successDelay: 300,
        failureDelays: [300, 900, 1_800, 3_600]
    )
    public static let codex = RefreshPolicy(delays: [60, 120, 300, 900])

    public let successDelay: TimeInterval
    public let failureDelays: [TimeInterval]
    public private(set) var failureLevel = 0

    public init(delays: [TimeInterval]) {
        precondition(!delays.isEmpty)
        successDelay = delays[0]
        let backoffDelays = Array(delays.dropFirst())
        failureDelays = backoffDelays.isEmpty ? [delays[0]] : backoffDelays
    }

    public init(successDelay: TimeInterval, failureDelays: [TimeInterval]) {
        precondition(successDelay > 0)
        precondition(!failureDelays.isEmpty)
        self.successDelay = successDelay
        self.failureDelays = failureDelays
    }

    public var nextDelay: TimeInterval {
        guard failureLevel > 0 else { return successDelay }
        return failureDelays[min(failureLevel - 1, failureDelays.count - 1)]
    }

    public mutating func recordSuccess() {
        failureLevel = 0
    }

    public mutating func recordFailure(shouldBackOff: Bool) {
        guard shouldBackOff else { return }
        failureLevel = min(failureLevel + 1, failureDelays.count)
    }
}
