import Foundation
import Testing
@testable import WattCore

struct ClaudeUsageProviderTests {
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-08-14T07:00:00Z")!

    @Test func decodesSessionWeeklyAndFableFromCLIOutput() throws {
        let snapshot = try ClaudeCLIUsageProvider.decode(
            envelope(#"""
            You are currently using your subscription to power your Claude Code usage

            Current session: 31.2% used · resets Aug 14 at 2:09pm (Europe/Sarajevo)
            Current week (all models): 48% used · resets Aug 20 at 12:59pm (Europe/Sarajevo)
            Current week (Fable): 17.4% used · resets Aug 20 at 1pm (Europe/Sarajevo)

            What's contributing to your limits usage?
            """#),
            fetchedAt: fetchedAt
        )

        let limits = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })
        #expect(limits["session"]?.percentage == 31.2)
        #expect(limits["weekly"]?.percentage == 48)
        #expect(limits["fable"]?.percentage == 17.4)
        #expect(limits.values.allSatisfy { $0.resetDate != nil })
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func missingFableIsUnavailableWithoutAffectingOtherLimits() throws {
        let snapshot = try ClaudeCLIUsageProvider.decode(envelope(#"""
        Current session: 22% used · resets Aug 14 at 2:09pm (Europe/Sarajevo)
        Current week (all models): 55% used · resets Aug 20 at 12:59pm (Europe/Sarajevo)
        """#), fetchedAt: fetchedAt)
        let limits = Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0) })

        #expect(limits["session"]?.percentage == 22)
        #expect(limits["weekly"]?.percentage == 55)
        #expect(limits["fable"]?.percentage == nil)
    }

    @Test func parsesResetAcrossCalendarYear() throws {
        let now = ISO8601DateFormatter().date(from: "2026-12-30T12:00:00Z")!
        let snapshot = try ClaudeCLIUsageProvider.decode(envelope(
            "Current week (all models): 55% used · resets Jan 2 at 12:59pm (Europe/Sarajevo)"
        ), fetchedAt: now)
        let resetDate = try #require(snapshot.limits.first { $0.id == "weekly" }?.resetDate)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Sarajevo"))
        #expect(calendar.component(.year, from: resetDate) == 2027)
        #expect(calendar.component(.month, from: resetDate) == 1)
        #expect(calendar.component(.day, from: resetDate) == 2)
    }

    @Test func rejectsUnknownOrMalformedOutput() {
        #expect(throws: ClaudeUsageError.changedResponse) {
            try ClaudeCLIUsageProvider.decode(envelope("Usage is looking good"))
        }
        #expect(throws: ClaudeUsageError.changedResponse) {
            try ClaudeCLIUsageProvider.decode(Data(#"{"result":42}"#.utf8))
        }
    }

    @Test func mapsCLIAuthenticationError() {
        #expect(throws: ClaudeUsageError.notLoggedIn) {
            try ClaudeCLIUsageProvider.decode(envelope("Not logged in · Please run /login", isError: true))
        }
    }

    @Test func providerDoesNotRunWithoutCLI() async {
        let provider = ClaudeCLIUsageProvider(executable: nil)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("Expected the provider to reject a missing CLI")
        } catch {
            #expect(error as? ClaudeUsageError == .cliUnavailable)
        }
    }

    @Test func providerExplainsUnsupportedAuthenticationAfterCommandFailure() async {
        let provider = ClaudeCLIUsageProvider(
            executable: URL(fileURLWithPath: "/bin/true"),
            runUsage: { _ in nil },
            configurationDetector: { .configured("Amazon Bedrock") }
        )
        do {
            _ = try await provider.fetchUsage()
            Issue.record("Expected the provider to reject non-subscription authentication")
        } catch {
            #expect(error as? ClaudeUsageError == .unsupportedAuthentication("Amazon Bedrock"))
        }
    }

    @Test func usageCommandUsesSafeNonInteractiveModeWithoutPersistence() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("claude-fixture")
        let script = #"""
        #!/bin/sh
        test "$1" = "--safe-mode" || exit 11
        test "$2" = "-p" || exit 12
        test "$3" = "/usage" || exit 13
        test "$4" = "--output-format" || exit 14
        test "$5" = "json" || exit 15
        test "$6" = "--no-session-persistence" || exit 16
        test "$LANG" = "C" || exit 17
        test "$LC_ALL" = "C" || exit 18
        test "$(pwd -P)" = "$(cd "$(dirname "$0")" && pwd -P)" || exit 19
        printf '%s' '{"is_error":false,"result":"Current session: 9% used"}'
        """#
        try Data(script.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let data = try #require(await ClaudeCLIUsageProvider.runUsageCommand(
            executable: executable,
            workingDirectory: directory
        ))
        let snapshot = try ClaudeCLIUsageProvider.decode(data)
        #expect(snapshot.limits.first { $0.id == "session" }?.percentage == 9)
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

    @Test func boundedProcessCapturesOutputAndOverridesEnvironment() async {
        let data = await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf \"$WATT_PROCESS_FIXTURE\""],
            environment: ["WATT_PROCESS_FIXTURE": "expected"],
            timeout: 1,
            maximumOutputBytes: 1_024
        )

        #expect(data == Data("expected".utf8))
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

    @Test func percentageNormalizationClampsToZeroThroughOneHundred() {
        #expect(UsageLimit(id: "a", name: "A", percentage: -5, resetDate: nil).percentage == 0)
        #expect(UsageLimit(id: "b", name: "B", percentage: 112, resetDate: nil).percentage == 100)
        #expect(UsageLimit(id: "c", name: "C", percentage: 42.6, resetDate: nil).roundedPercentage == 43)
        #expect(UsageLimit(id: "d", name: "D", percentage: nil, resetDate: nil).percentage == nil)
    }

    private func envelope(_ result: String, isError: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "is_error": isError,
            "result": result,
        ])
    }
}
