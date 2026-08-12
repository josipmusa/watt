import Foundation
import Testing
@testable import WattCore

struct ClaudeUsageProviderTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decodesSessionWeeklyAndFableFromCurrentSchema() throws {
        let data = Data(#"""
        {
          "five_hour": { "utilization": 31.2, "resets_at": "2026-08-11T12:30:00.000Z" },
          "seven_day": { "utilization": 48, "resets_at": "2026-08-14T09:00:00Z" },
          "limits": [
            {
              "kind": "weekly_scoped", "group": "model_fable", "percent": 17.4,
              "resets_at": "2026-08-15T09:00:00Z",
              "scope": { "model": { "display_name": "Fable" } }
            },
            {
              "kind": "weekly_scoped", "group": "another_model", "percent": 9,
              "resets_at": null, "scope": { "model": { "display_name": "Opus" } }
            }
          ],
          "extra_usage": { "is_enabled": false }
        }
        """#.utf8)

        let snapshot = try ClaudeOAuthUsageProvider.decode(data, fetchedAt: fetchedAt)
        let limits = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })
        #expect(limits["session"]?.percentage == 31.2)
        #expect(limits["weekly"]?.percentage == 48)
        #expect(limits["fable"]?.percentage == 17.4)
        #expect(snapshot.fetchedAt == fetchedAt)
        #expect(limits["session"]?.resetDate != nil)
        #expect(limits["weekly"]?.resetDate != nil)
        #expect(limits["fable"]?.resetDate != nil)
    }

    @Test func fableMatchingIsCaseInsensitiveAndGeneric() throws {
        let data = Data(#"""
        {
          "five_hour": null, "seven_day": null,
          "limits": [{
            "kind": "WEEKLY_SCOPED", "group": "server_chosen_group", "percent": 63,
            "resets_at": null, "scope": { "model": { "display_name": "Claude FABLE 5" } }
          }]
        }
        """#.utf8)

        let snapshot = try ClaudeOAuthUsageProvider.decode(data)
        let limits = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })
        #expect(limits["session"]?.percentage == nil)
        #expect(limits["weekly"]?.percentage == nil)
        #expect(limits["fable"]?.percentage == 63)
    }

    @Test func missingFableIsUnavailableWithoutAffectingOtherLimits() throws {
        let data = Data(#"""
        {
          "five_hour": { "utilization": 22, "resets_at": null },
          "seven_day": { "utilization": 55, "resets_at": null },
          "limits": []
        }
        """#.utf8)

        let snapshot = try ClaudeOAuthUsageProvider.decode(data)
        let limits = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })
        #expect(limits["session"]?.percentage == 22)
        #expect(limits["weekly"]?.percentage == 55)
        #expect(limits["fable"]?.percentage == nil)
    }

    @Test func unknownResponseShapeIsRejected() {
        let data = Data(#"{ "something_new": true }"#.utf8)
        #expect(throws: ClaudeUsageError.changedResponse) {
            try ClaudeOAuthUsageProvider.decode(data)
        }
    }

    @Test func malformedKnownFieldIsRejected() {
        let data = Data(#"{ "five_hour": "thirty percent" }"#.utf8)
        #expect(throws: ClaudeUsageError.changedResponse) {
            try ClaudeOAuthUsageProvider.decode(data)
        }
    }

    @Test func percentageNormalizationClampsToZeroThroughOneHundred() {
        #expect(UsageLimit(id: "a", name: "A", percentage: -5, resetDate: nil).percentage == 0)
        #expect(UsageLimit(id: "b", name: "B", percentage: 112, resetDate: nil).percentage == 100)
        #expect(UsageLimit(id: "c", name: "C", percentage: 42.6, resetDate: nil).roundedPercentage == 43)
        #expect(UsageLimit(id: "d", name: "D", percentage: nil, resetDate: nil).percentage == nil)
    }

    @Test func parsesRetryAfterSeconds() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "742"]
        ))

        #expect(ClaudeOAuthUsageProvider.retryAfterDelay(from: response) == 742)
    }

    @Test func parsesRetryAfterHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: now.addingTimeInterval(900))]
        ))

        #expect(ClaudeOAuthUsageProvider.retryAfterDelay(from: response, now: now) == 900)
    }

    @Test func detectsSubscriptionLoginWithoutRetainingIdentityFields() {
        let data = Data(#"""
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "fixture@example.invalid",
          "orgId": "fixture-org",
          "subscriptionType": "team"
        }
        """#.utf8)

        #expect(ClaudeConfigurationDetector.decode(data) == .subscription)
    }

    @Test func detectsNonSubscriptionClaudeConfiguration() {
        let data = Data(#"""
        {
          "loggedIn": true,
          "authMethod": "apiKey",
          "apiProvider": "bedrock",
          "subscriptionType": null
        }
        """#.utf8)

        #expect(ClaudeConfigurationDetector.decode(data) == .configured("Amazon Bedrock"))
    }

    @Test func boundedProcessCapturesOutput() async {
        let data = await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '{\"loggedIn\":true}'"],
            timeout: 1,
            maximumOutputBytes: 1_024
        )

        #expect(data == Data(#"{"loggedIn":true}"#.utf8))
    }

    @Test func boundedProcessStopsAtTimeout() async {
        let started = Date()
        let data = await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"],
            timeout: 0.05,
            maximumOutputBytes: 1_024
        )

        #expect(data == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func boundedProcessRejectsOversizedOutput() async {
        let data = await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 1234567890"],
            timeout: 1,
            maximumOutputBytes: 5
        )

        #expect(data == nil)
    }
}
