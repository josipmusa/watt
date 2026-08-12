import Foundation
import Security

public protocol CredentialProviding: Sendable {
    func accessToken(forceClaudeImport: Bool) throws -> String
    func discardImportedCredential() throws
}

public enum CredentialError: LocalizedError, Sendable {
    case notFound
    case invalidFormat
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Claude Code credentials were not found."
        case .invalidFormat: "Claude Code’s credential format was not recognized."
        case let .keychain(status): "Keychain error \(status)."
        }
    }
}

public final class ClaudeCodeCredentialProvider: CredentialProviding, @unchecked Sendable {
    // Claude Code uses this generic-password service for its macOS OAuth credential.
    private let claudeService = "Claude Code-credentials"
    private let wattService = "app.watt.Watt.oauth"
    private let wattAccount = "claude-oauth-access-token"
    private let lock = NSLock()

    public init() {}

    public func accessToken(forceClaudeImport: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if !forceClaudeImport, let cached = try readImportedCredential(),
           let token = String(data: cached, encoding: .utf8), !token.isEmpty {
            return token
        }

        let claudeCredential = try read(service: claudeService, account: nil, dataProtection: true)
            ?? read(service: claudeService, account: nil, dataProtection: false)
        guard let claudeCredential else {
            throw CredentialError.notFound
        }
        let token = try Self.extractAccessToken(from: claudeCredential)
        // Claude Code currently stores its OAuth blob in the user's classic login
        // Keychain. Watt does the same for its private copy so locally/ad-hoc signed
        // builds do not require a provisioning-team keychain access group.
        try write(Data(token.utf8), service: wattService, account: wattAccount, dataProtection: false)
        return token
    }

    public func discardImportedCredential() throws {
        lock.lock()
        defer { lock.unlock() }
        try delete(service: wattService, account: wattAccount, dataProtection: true)
        try delete(service: wattService, account: wattAccount, dataProtection: false)
    }

    static func extractAccessToken(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.invalidFormat
        }

        let containers: [[String: Any]] = [
            object["claudeAiOauth"] as? [String: Any],
            object["oauth"] as? [String: Any],
            object,
        ].compactMap { $0 }

        for container in containers {
            for key in ["accessToken", "access_token"] {
                if let token = container[key] as? String, !token.isEmpty { return token }
            }
        }
        throw CredentialError.invalidFormat
    }

    private func read(service: String, account: String?, dataProtection: Bool) throws -> Data? {
        var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialError.keychain(status)
        }
        return data
    }

    private func readImportedCredential() throws -> Data? {
        try read(service: wattService, account: wattAccount, dataProtection: true)
            ?? read(service: wattService, account: wattAccount, dataProtection: false)
    }

    private func write(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        let query = baseQuery(service: service, account: account, dataProtection: dataProtection)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }

    private func delete(service: String, account: String, dataProtection: Bool) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account, dataProtection: dataProtection) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
