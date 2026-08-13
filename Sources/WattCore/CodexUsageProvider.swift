import Foundation

public enum CodexUsageError: HarnessUsageProviderError, Equatable, Sendable {
    case cliNotFound
    case configuredCLIUnavailable
    case notSignedIn
    case unsupportedAccount(String)
    case launchFailed
    case connectionClosed
    case timedOut
    case protocolError(String)
    case changedResponse

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex isn’t installed in a standard location."
        case .configuredCLIUnavailable:
            "Codex is configured, but Watt couldn’t find its CLI. Set WATT_CODEX_PATH to the executable."
        case .notSignedIn:
            "Codex is installed but isn’t signed in."
        case let .unsupportedAccount(type):
            "Codex is configured with \(type), which doesn’t expose subscription limits."
        case .launchFailed:
            "Watt couldn’t start the local Codex usage service."
        case .connectionClosed:
            "The local Codex usage service stopped unexpectedly."
        case .timedOut:
            "The local Codex usage service didn’t respond."
        case let .protocolError(message):
            "Codex returned an error: \(message)"
        case .changedResponse:
            "Codex’s usage response has changed."
        }
    }

    public var shouldBackOff: Bool {
        switch self {
        case .launchFailed, .connectionClosed, .timedOut, .protocolError: true
        default: false
        }
    }

    public var isNotConfigured: Bool {
        switch self {
        case .cliNotFound, .notSignedIn: true
        default: false
        }
    }
}

public actor CodexAppServerUsageProvider: HarnessUsageProviding {
    public nonisolated let harness = HarnessKind.codex

    // `codex app-server` is currently experimental. Keep all protocol details
    // in this provider/client pair so schema changes remain localized.
    private let executableResolver: @Sendable () -> URL?
    private let configurationDetector: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var client: CodexAppServerClient?

    public init(
        executableResolver: @escaping @Sendable () -> URL? = { CodexCLIResolver.findExecutable() },
        configurationDetector: @escaping @Sendable () -> Bool = { CodexCLIResolver.hasConfiguration() },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.executableResolver = executableResolver
        self.configurationDetector = configurationDetector
        self.now = now
    }

    public func fetchUsage() async throws -> HarnessUsageSnapshot {
        let client: CodexAppServerClient
        if let existing = self.client {
            client = existing
        } else {
            guard let executableURL = executableResolver() else {
                throw configurationDetector()
                    ? CodexUsageError.configuredCLIUnavailable
                    : CodexUsageError.cliNotFound
            }
            let created = CodexAppServerClient(executableURL: executableURL)
            self.client = created
            client = created
        }

        do {
            let accountData = try await client.request(method: "account/read", params: ["refreshToken": false])
            let accountType = try Self.decodeAccountType(accountData)
            guard let accountType else { throw CodexUsageError.notSignedIn }
            guard accountType == "chatgpt" else {
                throw CodexUsageError.unsupportedAccount(Self.displayName(for: accountType))
            }

            let limitsData = try await client.request(method: "account/rateLimits/read")
            return try Self.decodeRateLimits(limitsData, fetchedAt: now())
        } catch let error as CodexUsageError {
            if error == .connectionClosed || error == .launchFailed {
                self.client = nil
            }
            throw error
        } catch {
            self.client = nil
            throw CodexUsageError.connectionClosed
        }
    }

    static func decodeAccountType(_ data: Data) throws -> String? {
        let envelope: AccountEnvelope
        do {
            envelope = try JSONDecoder().decode(AccountEnvelope.self, from: data)
        } catch {
            throw CodexUsageError.changedResponse
        }
        return envelope.result.account?.type
    }

    public static func decodeRateLimits(
        _ data: Data,
        fetchedAt: Date = .now
    ) throws -> HarnessUsageSnapshot {
        let envelope: RateLimitsEnvelope
        do {
            envelope = try JSONDecoder().decode(RateLimitsEnvelope.self, from: data)
        } catch {
            throw CodexUsageError.changedResponse
        }

        let rateLimits = envelope.result.rateLimits
        // App-server has used both bucket positions across versions. Identify
        // the weekly limit by its duration, then fall back to the historically
        // weekly secondary bucket when duration metadata is unavailable.
        let weekly = [rateLimits.primary, rateLimits.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == 10_080 }
            ?? rateLimits.secondary
        guard let weekly else { throw CodexUsageError.changedResponse }

        return HarnessUsageSnapshot(
            harness: .codex,
            limits: [Self.makeLimit(id: "weekly", window: weekly, fallbackName: "Weekly")],
            fetchedAt: fetchedAt
        )
    }

    private static func makeLimit(id: String, window: RateLimitWindow, fallbackName: String) -> UsageLimit {
        UsageLimit(
            id: id,
            name: windowName(minutes: window.windowDurationMins) ?? fallbackName,
            percentage: window.usedPercent,
            resetDate: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func windowName(minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) day" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour" }
        return "\(minutes) min"
    }

    private static func displayName(for accountType: String) -> String {
        switch accountType {
        case "apiKey": "an API key"
        case "amazonBedrock": "Amazon Bedrock"
        default: accountType
        }
    }
}

public enum CodexCLIResolver {
    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        var paths: [String] = []
        if let override = environment["WATT_CODEX_PATH"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            homeDirectory.appendingPathComponent(".codex/bin/codex").path,
            homeDirectory.appendingPathComponent(".npm-global/bin/codex").path,
            homeDirectory.appendingPathComponent(".bun/bin/codex").path,
            homeDirectory.appendingPathComponent(".volta/bin/codex").path,
            homeDirectory.appendingPathComponent(".asdf/shims/codex").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims/codex").path,
            homeDirectory.appendingPathComponent("Library/pnpm/codex").path,
            "/Applications/Codex.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])
        paths.append(contentsOf: versionManagerCandidates(homeDirectory: homeDirectory, fileManager: fileManager))
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        return LocalExecutableResolver.firstTrusted(in: paths, fileManager: fileManager)
    }

    public static func hasConfiguration(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return ["auth.json", "config.toml"].contains {
            fileManager.fileExists(atPath: codexHome.appendingPathComponent($0).path)
        }
    }

    private static func versionManagerCandidates(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [String] {
        let roots = [
            homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true),
            homeDirectory.appendingPathComponent(".nodenv/versions", isDirectory: true),
        ]
        return roots.flatMap { root in
            let versions = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return versions.map { $0.appendingPathComponent("bin/codex").path }
        }
    }
}

enum LocalExecutableResolver {
    /// Resolve symlinks before launching and reject binaries that another local
    /// user could replace directly. Explicit WATT_* overrides still use this
    /// check; they are an escape hatch for location, not for unsafe permissions.
    static func firstTrusted(in paths: [String], fileManager: FileManager = .default) -> URL? {
        var seen = Set<String>()
        for path in paths {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted,
                  isTrustedExecutable(resolved, fileManager: fileManager) else { continue }
            return resolved
        }
        return nil
    }

    static func isTrustedExecutable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let ownerID = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              hasTrustedOwnership(ownerID: ownerID, permissions: permissions),
              let parentAttributes = try? fileManager.attributesOfItem(
                  atPath: url.deletingLastPathComponent().path
              ),
              let parentOwnerID = parentAttributes[.ownerAccountID] as? NSNumber,
              let parentPermissions = parentAttributes[.posixPermissions] as? NSNumber else { return false }

        return hasTrustedOwnership(ownerID: parentOwnerID, permissions: parentPermissions)
    }

    private static func hasTrustedOwnership(ownerID: NSNumber, permissions: NSNumber) -> Bool {
        let owner = ownerID.uint32Value
        guard owner == 0 || owner == getuid() else { return false }
        return permissions.uint16Value & 0o022 == 0
    }
}

private actor CodexAppServerClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    private let executableURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [Int: PendingRequest] = [:]
    private var nextID = 1
    private var initialized = false

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    deinit {
        readerTask?.cancel()
        process?.terminate()
    }

    func request(method: String, params: [String: Any]? = nil) async throws -> Data {
        try await ensureStarted()
        return try await sendRequest(method: method, params: params)
    }

    private func ensureStarted() async throws {
        if initialized, process?.isRunning == true { return }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexUsageError.launchFailed
        }

        self.process = process
        input = stdin.fileHandleForWriting
        startReading(stdout.fileHandleForReading)

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "watt",
                        "title": "Watt",
                        "version": "1.0",
                    ],
                ]
            )
            try sendNotification(method: "initialized", params: [:])
            initialized = true
        } catch {
            readerTask?.cancel()
            process.terminate()
            self.process = nil
            input = nil
            throw error
        }
    }

    private func startReading(_ output: FileHandle) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    guard let data = line.data(using: .utf8) else { continue }
                    await self?.receive(data)
                }
            } catch {
                // The process-closed path below reports a stable error to callers.
            }
            await self?.connectionDidClose()
        }
    }

    private func sendRequest(method: String, params: [String: Any]? = nil) async throws -> Data {
        guard let input else { throw CodexUsageError.connectionClosed }
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["method": method, "id": id]
        if let params { message["params"] = params }
        let data = try encodeLine(message)

        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.requestTimedOut(id)
            }
            pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
            do {
                try input.write(contentsOf: data)
            } catch {
                if let request = pending.removeValue(forKey: id) {
                    request.timeout.cancel()
                    request.continuation.resume(throwing: CodexUsageError.connectionClosed)
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try input?.write(contentsOf: encodeLine(["method": method, "params": params]))
    }

    private func encodeLine(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexUsageError.changedResponse
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private func receive(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? Int,
            let request = pending.removeValue(forKey: id)
        else { return }

        request.timeout.cancel()
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown app-server error"
            request.continuation.resume(throwing: CodexUsageError.protocolError(message))
        } else {
            request.continuation.resume(returning: data)
        }
    }

    private func requestTimedOut(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CodexUsageError.timedOut)
    }

    private func connectionDidClose() {
        guard process != nil else { return }
        initialized = false
        process = nil
        input = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: CodexUsageError.connectionClosed)
        }
    }
}

private struct AccountEnvelope: Decodable {
    let result: AccountResult
}

private struct AccountResult: Decodable {
    let account: CodexAccount?
}

private struct CodexAccount: Decodable {
    let type: String
}

private struct RateLimitsEnvelope: Decodable {
    let result: RateLimitsResult
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitBucket
}

private struct RateLimitBucket: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}
