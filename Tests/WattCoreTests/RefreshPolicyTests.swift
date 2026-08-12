import Testing
@testable import WattCore

struct RefreshPolicyTests {
    @Test func backoffProgressesAndCaps() {
        var policy = RefreshPolicy(delays: [60, 120, 300])
        #expect(policy.nextDelay == 60)
        policy.recordFailure(shouldBackOff: true)
        #expect(policy.nextDelay == 120)
        policy.recordFailure(shouldBackOff: true)
        #expect(policy.nextDelay == 300)
        policy.recordFailure(shouldBackOff: true)
        #expect(policy.nextDelay == 300)
    }

    @Test func successRestoresNormalInterval() {
        var policy = RefreshPolicy(delays: [60, 120, 300])
        policy.recordFailure(shouldBackOff: true)
        policy.recordFailure(shouldBackOff: true)
        policy.recordSuccess()
        #expect(policy.nextDelay == 60)
    }

    @Test func nonTransientFailureDoesNotIncreaseBackoff() {
        var policy = RefreshPolicy(delays: [60, 120, 300])
        policy.recordFailure(shouldBackOff: false)
        #expect(policy.nextDelay == 60)
    }
}
