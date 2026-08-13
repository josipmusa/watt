import Foundation
import Testing
@testable import WattCore

struct CodexUsageProviderTests {
    @Test func decodesOnlyTheWeeklyWindow() throws {
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
        #expect(snapshot.limits.map(\.id) == ["weekly"])
        #expect(snapshot.limits.map(\.name) == ["Weekly"])
        #expect(snapshot.limits.map(\.percentage) == [47])
        #expect(snapshot.limits.allSatisfy { $0.resetDate != nil })
        #expect(snapshot.fetchedAt == fetchedAt)
    }

    @Test func findsWeeklyWindowInPrimaryBucket() throws {
        let data = Data(#"""
        {
          "id": 6,
          "result": {
            "rateLimits": {
              "primary": { "usedPercent": 31, "windowDurationMins": 10080, "resetsAt": 1800604800 },
              "secondary": null
            }
          }
        }
        """#.utf8)

        let snapshot = try CodexAppServerUsageProvider.decodeRateLimits(data)
        #expect(snapshot.limits.first?.id == "weekly")
        #expect(snapshot.limits.first?.percentage == 31)
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
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/codex") {
            #expect(found != nil)
        }
    }

    @Test func checksCodexBundledWithChatGPT() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let candidates = CodexCLIResolver.applicationBundleCandidates(homeDirectory: homeDirectory)

        #expect(candidates.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        #expect(candidates.contains("/Users/example/Applications/ChatGPT.app/Contents/Resources/codex"))
    }

    @Test func resolverRejectsWritableExecutableAndResolvesSymlink() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex-real")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let link = directory.appendingPathComponent("codex")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)

        #expect(LocalExecutableResolver.firstTrusted(in: [link.path]) == executable)

        try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)
        #expect(LocalExecutableResolver.firstTrusted(in: [link.path]) == nil)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(LocalExecutableResolver.firstTrusted(in: [link.path]) == nil)
    }
}
