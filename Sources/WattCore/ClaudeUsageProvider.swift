import Foundation

public enum ClaudeUsageError: HarnessUsageProviderError, Equatable, Sendable {
    case cliUnavailable
    case notLoggedIn
    case unsupportedAuthentication(String)
    case commandFailed
    case changedResponse

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            "Claude Code wasn’t found. Install Claude Code to monitor its usage."
        case .notLoggedIn:
            "Claude Code isn’t signed in. Open Claude Code and sign in first."
        case let .unsupportedAuthentication(method):
            "Claude is configured with \(method), which doesn’t expose subscription limits to Watt."
        case .commandFailed:
            "Watt couldn’t ask Claude Code for usage. Update Claude Code, then refresh."
        case .changedResponse:
            "Claude Code’s usage output has changed."
        }
    }

    public var shouldBackOff: Bool {
        switch self {
        case .commandFailed: true
        default: false
        }
    }

    public var isNotConfigured: Bool {
        switch self {
        case .cliUnavailable, .notLoggedIn: true
        default: false
        }
    }

    public var retryAfter: TimeInterval? { nil }
}

/// Retrieves subscription limits through Claude Code itself. Claude remains
/// responsible for its credentials, so Watt never reads or handles OAuth tokens.
public actor ClaudeCLIUsageProvider: HarnessUsageProviding {
    public nonisolated let harness = HarnessKind.claude

    private let executable: URL?
    private let now: @Sendable () -> Date
    private let runUsage: @Sendable (URL) async -> Data?
    private let configurationDetector: @Sendable () async -> ClaudeConfigurationStatus

    public init(
        executable: URL? = ClaudeCLIResolver.findExecutable(),
        now: @escaping @Sendable () -> Date = { .now },
        runUsage: (@Sendable (URL) async -> Data?)? = nil,
        configurationDetector: @escaping @Sendable () async -> ClaudeConfigurationStatus = {
            await ClaudeConfigurationDetector.detect()
        }
    ) {
        self.executable = executable
        self.now = now
        self.runUsage = runUsage ?? { executable in
            await ClaudeCLIUsageProvider.runUsageCommand(executable: executable)
        }
        self.configurationDetector = configurationDetector
    }

    public func fetchUsage() async throws -> HarnessUsageSnapshot {
        guard let executable else { throw ClaudeUsageError.cliUnavailable }
        guard let data = await runUsage(executable) else {
            throw await failureForCurrentConfiguration()
        }

        do {
            return try Self.decode(data, fetchedAt: now())
        } catch let error as ClaudeUsageError {
            if error == .changedResponse {
                throw await failureForCurrentConfiguration(fallback: error)
            }
            throw error
        }
    }

    public static func decode(
        _ data: Data,
        fetchedAt: Date = .now,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> HarnessUsageSnapshot {
        let envelope: ClaudeUsageEnvelope
        do {
            envelope = try JSONDecoder().decode(ClaudeUsageEnvelope.self, from: data)
        } catch {
            throw ClaudeUsageError.changedResponse
        }

        let result = envelope.result.trimmingCharacters(in: .whitespacesAndNewlines)
        if envelope.isError {
            let normalized = result.lowercased()
            if normalized.contains("not logged in") || normalized.contains("please run /login") {
                throw ClaudeUsageError.notLoggedIn
            }
            throw ClaudeUsageError.commandFailed
        }

        let parsed = parseLimits(from: result, now: fetchedAt, calendar: calendar)
        guard parsed.session != nil || parsed.weekly != nil || parsed.fable != nil else {
            throw ClaudeUsageError.changedResponse
        }

        return HarnessUsageSnapshot(
            harness: .claude,
            limits: [
                UsageLimit(
                    id: "session",
                    name: "Session",
                    percentage: parsed.session?.percentage,
                    resetDate: parsed.session?.resetDate
                ),
                UsageLimit(
                    id: "weekly",
                    name: "Weekly",
                    percentage: parsed.weekly?.percentage,
                    resetDate: parsed.weekly?.resetDate
                ),
                UsageLimit(
                    id: "fable",
                    name: "Fable",
                    percentage: parsed.fable?.percentage,
                    resetDate: parsed.fable?.resetDate
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    static func runUsageCommand(
        executable: URL,
        workingDirectory: URL = defaultWorkingDirectory
    ) async -> Data? {
        do {
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        return await BoundedProcess.run(
            executable: executable,
            arguments: [
                "--safe-mode",
                "-p", "/usage",
                "--output-format", "json",
                "--no-session-persistence",
            ],
            environment: [
                "LANG": "C",
                "LC_ALL": "C",
                "NO_COLOR": "1",
            ],
            workingDirectory: workingDirectory,
            timeout: 10,
            maximumOutputBytes: 1_048_576
        )
    }

    private static var defaultWorkingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Watt", isDirectory: true)
            .appendingPathComponent("ClaudeCLI", isDirectory: true)
    }

    private func failureForCurrentConfiguration(
        fallback: ClaudeUsageError = .commandFailed
    ) async -> ClaudeUsageError {
        switch await configurationDetector() {
        case .notConfigured: .notLoggedIn
        case .subscription: fallback
        case let .configured(method): .unsupportedAuthentication(method)
        }
    }

    private static func parseLimits(
        from result: String,
        now: Date,
        calendar: Calendar
    ) -> ParsedLimits {
        var limits = ParsedLimits()
        for line in result.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Current session:") {
                limits.session = parseLimitLine(line, now: now, calendar: calendar)
            } else if line.hasPrefix("Current week (all models):") {
                limits.weekly = parseLimitLine(line, now: now, calendar: calendar)
            } else if line.range(of: "Current week (Fable", options: .caseInsensitive) != nil {
                limits.fable = parseLimitLine(line, now: now, calendar: calendar)
            }
        }
        return limits
    }

    private static func parseLimitLine(
        _ line: String,
        now: Date,
        calendar: Calendar
    ) -> ParsedLimit? {
        guard let percentageRange = line.range(
            of: #"[0-9]+(?:\.[0-9]+)?(?=% used)"#,
            options: .regularExpression
        ), let percentage = Double(line[percentageRange]) else { return nil }

        let resetMarker = "resets "
        let resetDate = line.range(of: resetMarker).flatMap { marker in
            parseResetDate(String(line[marker.upperBound...]), now: now, calendar: calendar)
        }
        return ParsedLimit(percentage: percentage, resetDate: resetDate)
    }

    private static func parseResetDate(
        _ value: String,
        now: Date,
        calendar baseCalendar: Calendar
    ) -> Date? {
        let pattern = #"^([A-Z][a-z]{2}) ([0-9]{1,2}) at ([0-9]{1,2})(?::([0-9]{2}))?(am|pm) \(([^)]+)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges == 7 else { return nil }

        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }

        let months = [
            "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4,
            "May": 5, "Jun": 6, "Jul": 7, "Aug": 8,
            "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
        ]
        guard let monthName = capture(1), let month = months[monthName],
              let dayText = capture(2), let day = Int(dayText),
              let hourText = capture(3), var hour = Int(hourText),
              let meridiem = capture(5),
              let timeZoneName = capture(6), let timeZone = TimeZone(identifier: timeZoneName) else {
            return nil
        }
        let minute = capture(4).flatMap(Int.init) ?? 0

        hour %= 12
        if meridiem == "pm" { hour += 12 }

        var calendar = baseCalendar
        calendar.timeZone = timeZone
        let currentYear = calendar.component(.year, from: now)
        var components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: currentYear,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        guard var date = calendar.date(from: components) else { return nil }
        if date < now.addingTimeInterval(-3_600) {
            components.year = currentYear + 1
            guard let nextYear = calendar.date(from: components) else { return nil }
            date = nextYear
        }
        return date
    }
}

public enum ClaudeCLIResolver {
    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        var paths: [String] = []
        if let override = environment["WATT_CLAUDE_PATH"], !override.isEmpty {
            paths.append(override)
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
        paths.append(contentsOf: versionManagerCandidates(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ))
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }
        return LocalExecutableResolver.firstTrusted(in: paths, fileManager: fileManager)
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
            return versions.map { $0.appendingPathComponent("bin/claude").path }
        }
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

        guard let executable = ClaudeCLIResolver.findExecutable(
            environment: environment,
            homeDirectory: homeDirectory
        ), let data = await runAuthStatus(executable: executable) else {
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

    static func runAuthStatus(executable: URL) async -> Data? {
        await BoundedProcess.run(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            timeout: 10,
            maximumOutputBytes: 1_048_576
        )
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

enum BoundedProcess {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            ProcessCapture(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes,
                continuation: continuation
            ).start()
        }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL?
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private var continuation: CheckedContinuation<Data?, Never>?
    private var process: Process?
    private var outputHandle: FileHandle?
    private var output = Data()
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        continuation: CheckedContinuation<Data?, Never>
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.continuation = continuation
    }

    func start() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        outputHandle = pipe.fileHandleForReading

        pipe.fileHandleForReading.readabilityHandler = { handle in
            self.append(handle.availableData)
        }
        process.terminationHandler = { process in
            self.processTerminated(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            finish(with: nil, terminate: false)
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(with: nil, terminate: true)
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, timeout),
            execute: timeoutWorkItem
        )
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let exceedsLimit = output.count + data.count > maximumOutputBytes
        if !exceedsLimit { output.append(data) }
        lock.unlock()
        if exceedsLimit { finish(with: nil, terminate: true) }
    }

    private func processTerminated(status: Int32) {
        outputHandle?.readabilityHandler = nil
        if let handle = outputHandle, let trailing = try? handle.readToEnd(), !trailing.isEmpty {
            append(trailing)
        }

        lock.lock()
        let result = status == 0 && output.count <= maximumOutputBytes ? output : nil
        lock.unlock()
        finish(with: result, terminate: false)
    }

    private func finish(with result: Data?, terminate: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let process = self.process
        self.process = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        process?.terminationHandler = nil
        lock.unlock()

        if terminate, process?.isRunning == true { process?.terminate() }
        continuation.resume(returning: result)
    }
}

private struct ClaudeUsageEnvelope: Decodable {
    let isError: Bool
    let result: String

    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case result
    }
}

private struct ParsedLimits {
    var session: ParsedLimit?
    var weekly: ParsedLimit?
    var fable: ParsedLimit?
}

private struct ParsedLimit {
    let percentage: Double
    let resetDate: Date?
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String
    let apiProvider: String?
    let subscriptionType: String?
}
