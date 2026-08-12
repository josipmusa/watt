import Foundation
import Testing
@testable import WattCore

struct CodexUsageProviderTests {
    @Test func decodesPrimaryAndSecondaryWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"""
        {
          "id": 6,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": { "usedPercent": 23.4, "windowDurationMins": 300, "resetsAt": 1800003600 },
              "secondary": { "usedPercent": 47, "windowDurationMins": 10080, "resetsAt": 1800604800 }
            }
          }
        }
        """#.utf8)

        let snapshot = try CodexAppServerUsageProvider.decodeRateLimits(data, fetchedAt: fetchedAt)
        #expect(snapshot.harness == .codex)
        #expect(snapshot.limits.map(\.name) == ["5 hour", "Weekly"])
        #expect(snapshot.limits.map(\.percentage) == [23.4, 47])
        #expect(snapshot.limits.allSatisfy { $0.resetDate != nil })
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func rejectsResponseWithoutUsageWindows() {
        let data = Data(#"{ "id": 6, "result": { "rateLimits": { "primary": null, "secondary": null } } }"#.utf8)
        #expect(throws: CodexUsageError.changedResponse) {
            try CodexAppServerUsageProvider.decodeRateLimits(data)
        }
    }

    @Test func findsStandardCodexInstallation() {
        let found = CodexCLIResolver.findExecutable()
        #expect(found == nil || FileManager.default.isExecutableFile(atPath: found!.path))
    }
}
