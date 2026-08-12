import Foundation
import Testing
@testable import WattCore

struct CredentialProviderTests {
    @Test func extractsCurrentClaudeCodeCredentialShape() throws {
        let data = Data(#"{ "claudeAiOauth": { "accessToken": "fixture-not-a-real-credential" } }"#.utf8)
        #expect(try ClaudeCodeCredentialProvider.extractAccessToken(from: data) == "fixture-not-a-real-credential")
    }

    @Test func rejectsCredentialWithoutAccessToken() {
        let data = Data(#"{ "claudeAiOauth": { "expiresAt": 123 } }"#.utf8)
        #expect(throws: CredentialError.self) {
            try ClaudeCodeCredentialProvider.extractAccessToken(from: data)
        }
    }
}
