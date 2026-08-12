import Foundation

public enum ClaudeUsageError: HarnessUsageProviderError, Equatable, Sendable {
    case credentialsUnavailable
    case subscriptionCredentialUnavailable
    case credentialAccessDenied
    case credentialFormatChanged
    case unsupportedAuthentication(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case changedResponse
    case invalidResponse
    case network

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable: "Claude Code credentials weren’t found. Open Claude Code and sign in first."
        case .subscriptionCredentialUnavailable: "Claude is signed in, but Watt couldn’t find its subscription credential in Keychain."
        case .credentialAccessDenied: "Watt couldn’t access the Claude credential in Keychain. Allow access when macOS asks, then refresh."
        case .credentialFormatChanged: "Claude Code’s credential format has changed."
        case let .unsupportedAuthentication(method): "Claude is configured with \(method), which doesn’t expose subscription limits to Watt."
        case .unauthorized: "Claude’s sign-in has expired. Open Claude Code to sign in again."
        case .rateLimited: "Claude usage is temporarily rate limited. Watt will retry automatically."
        case .server: "Claude usage is temporarily unavailable."
        case .changedResponse: "Claude’s usage response has changed."
        case .invalidResponse: "Claude returned an invalid usage response."
        case .network: "The network is unavailable."
        }
    }

    public var shouldBackOff: Bool {
        switch self {
        case .rateLimited, .server, .network: true
        default: false
        }
    }

    public var isNotConfigured: Bool {
        self == .credentialsUnavailable
    }

    public var retryAfter: TimeInterval? {
        if case let .rateLimited(retryAfter) = self { return retryAfter }
        return nil
    }
}

public actor ClaudeOAuthUsageProvider: HarnessUsageProviding {
    public nonisolated let harness = HarnessKind.claude
    // This undocumented API contract is intentionally confined to this type and its private DTOs.
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthBeta = "oauth-2025-04-20"

    private let credentials: any CredentialProviding
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let configurationDetector: @Sendable () async -> ClaudeConfigurationStatus

    public init(
        credentials: any CredentialProviding,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { .now },
        configurationDetector: @escaping @Sendable () async -> ClaudeConfigurationStatus = {
            await ClaudeConfigurationDetector.detect()
        }
    ) {
        self.credentials = credentials
        self.session = session
        self.now = now
        self.configurationDetector = configurationDetector
    }

    public func fetchUsage() async throws -> HarnessUsageSnapshot {
        do {
            return try await request(forceClaudeImport: false)
        } catch ClaudeUsageError.unauthorized {
            try? credentials.discardImportedCredential()
            return try await request(forceClaudeImport: true)
        }
    }

    private func request(forceClaudeImport: Bool) async throws -> HarnessUsageSnapshot {
        let token: String
        do {
            token = try credentials.accessToken(forceClaudeImport: forceClaudeImport)
        } catch CredentialError.notFound {
            switch await configurationDetector() {
            case .notConfigured:
                throw ClaudeUsageError.credentialsUnavailable
            case .subscription:
                throw ClaudeUsageError.subscriptionCredentialUnavailable
            case let .configured(method):
                throw ClaudeUsageError.unsupportedAuthentication(method)
            }
        } catch CredentialError.invalidFormat {
            throw ClaudeUsageError.credentialFormatChanged
        } catch {
            throw ClaudeUsageError.credentialAccessDenied
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeUsageError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.invalidResponse
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ClaudeUsageError.unauthorized
        case 429:
            throw ClaudeUsageError.rateLimited(
                retryAfter: Self.retryAfterDelay(from: http, now: now())
            )
        case 500...599: throw ClaudeUsageError.server(http.statusCode)
        default: throw ClaudeUsageError.invalidResponse
        }

        return try Self.decode(data, fetchedAt: now())
    }

    public static func decode(_ data: Data, fetchedAt: Date = .now) throws -> HarnessUsageSnapshot {
        let decoder = JSONDecoder()
        let response: UsageResponseDTO
        do {
            response = try decoder.decode(UsageResponseDTO.self, from: data)
        } catch {
            throw ClaudeUsageError.changedResponse
        }

        guard response.hasKnownUsageField else {
            throw ClaudeUsageError.changedResponse
        }

        let fable = response.limits?.first(where: { limit in
            limit.kind.caseInsensitiveCompare("weekly_scoped") == .orderedSame &&
            limit.scope?.model?.displayName.range(of: "fable", options: .caseInsensitive) != nil
        })

        return HarnessUsageSnapshot(
            harness: .claude,
            limits: [
                UsageLimit(
                    id: "session",
                    name: "Session",
                    percentage: response.fiveHour?.utilization,
                    resetDate: parseDate(response.fiveHour?.resetsAt)
                ),
                UsageLimit(
                    id: "weekly",
                    name: "Weekly",
                    percentage: response.sevenDay?.utilization,
                    resetDate: parseDate(response.sevenDay?.resetsAt)
                ),
                UsageLimit(
                    id: "fable",
                    name: "Fable",
                    percentage: fable?.percent,
                    resetDate: parseDate(fable?.resetsAt)
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func retryAfterDelay(from response: HTTPURLResponse, now: Date = .now) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

public enum ClaudeConfigurationStatus: Equatable, Sendable {
    case notConfigured
    case subscription
    case configured(String)
}

public enum ClaudeConfigurationDetector {
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> ClaudeConfigurationStatus {
        if environment["CLAUDE_CODE_OAUTH_TOKEN"]?.isEmpty == false {
            return .configured("an OAuth environment token")
        }
        if environment["ANTHROPIC_AUTH_TOKEN"]?.isEmpty == false {
            return .configured("an authentication token")
        }
        if environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return .configured("an API key")
        }
        if isEnabled(environment["CLAUDE_CODE_USE_BEDROCK"]) {
            return .configured("Amazon Bedrock")
        }
        if isEnabled(environment["CLAUDE_CODE_USE_VERTEX"]) {
            return .configured("Google Vertex AI")
        }
        if isEnabled(environment["CLAUDE_CODE_USE_FOUNDRY"]) {
            return .configured("Microsoft Foundry")
        }

        guard let executable = findExecutable(environment: environment, homeDirectory: homeDirectory) else {
            return .notConfigured
        }
        guard let data = await runAuthStatus(executable: executable) else {
            return .notConfigured
        }
        return decode(data)
    }

    public static func decode(_ data: Data) -> ClaudeConfigurationStatus {
        guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data), status.loggedIn else {
            return .notConfigured
        }
        if status.authMethod.caseInsensitiveCompare("claude.ai") == .orderedSame {
            return .subscription
        }
        if let subscription = status.subscriptionType, !subscription.isEmpty {
            return .subscription
        }
        let method = status.apiProvider ?? status.authMethod
        return .configured(displayName(for: method))
    }

    private static func findExecutable(
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var paths: [String] = []
        if let override = environment["WATT_CLAUDE_PATH"], !override.isEmpty {
            paths.append(override)
        }
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            homeDirectory.appendingPathComponent(".local/bin/claude").path,
            homeDirectory.appendingPathComponent(".claude/local/claude").path,
            homeDirectory.appendingPathComponent(".npm-global/bin/claude").path,
            homeDirectory.appendingPathComponent(".bun/bin/claude").path,
            homeDirectory.appendingPathComponent(".volta/bin/claude").path,
            homeDirectory.appendingPathComponent(".asdf/shims/claude").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims/claude").path,
            homeDirectory.appendingPathComponent("Library/pnpm/claude").path,
        ])
        return paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runAuthStatus(executable: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["auth", "status", "--json"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func displayName(for method: String) -> String {
        switch method.lowercased() {
        case "apikey", "api_key": "an API key"
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case "foundry": "Microsoft Foundry"
        default: method
        }
    }

    private static func isEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String
    let apiProvider: String?
    let subscriptionType: String?
}

private struct UsageResponseDTO: Decodable {
    let fiveHour: UsageWindowDTO?
    let sevenDay: UsageWindowDTO?
    let limits: [ScopedLimitDTO]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    var hasKnownUsageField: Bool {
        fiveHour != nil || sevenDay != nil || limits != nil
    }
}

private struct UsageWindowDTO: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct ScopedLimitDTO: Decodable {
    let kind: String
    let group: String
    let percent: Double
    let resetsAt: String?
    let scope: ScopeDTO?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

private struct ScopeDTO: Decodable {
    let model: ModelDTO?
}

private struct ModelDTO: Decodable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}
