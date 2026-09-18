import Foundation
import GoogleAuthKit
import Testing

@testable import GooglePlayMCPServer

/// `Entry.swift` hosts the process `@main` entry point, whose `main()` blocks on the stdio
/// transport and can't be driven from a test. This suite covers what's separable from that:
/// CLI-argument parsing, the version/usage strings, and the credential-resolution error path.
@Suite("Entry point", .serialized)
struct EntryTests {

    @Test(
        "CLIMode reads the version and help flags",
        arguments: [
            (["google-play-store-mcp"], CLIMode.serve),
            (["google-play-store-mcp", "--version"], .version),
            (["google-play-store-mcp", "-v"], .version),
            (["google-play-store-mcp", "--help"], .help),
            (["google-play-store-mcp", "-h"], .help),
            (["google-play-store-mcp", "--unknown-flag"], .serve),
        ])
    func cliModeParsing(arguments: [String], expected: CLIMode) {
        #expect(CLIMode(arguments: arguments) == expected)
    }

    @Test("the version string is non-empty")
    func versionIsNonEmpty() {
        #expect(!GooglePlayMCPVersion.current.isEmpty)
    }

    @Test("usage text documents every credential env var and the write-gate flag")
    func usageDocumentsCredentials() {
        let usage = GooglePlayMCP.usage
        #expect(usage.contains("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"))
        #expect(usage.contains("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH"))
        #expect(usage.contains("GOOGLE_APPLICATION_CREDENTIALS"))
        #expect(usage.contains("GOOGLE_PLAY_ENABLE_WRITES"))
    }

    @Test("makeClient reports a readable error when no credentials are configured")
    func makeClientFailsWithoutCredentials() throws {
        let saved = [
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH",
            "GOOGLE_APPLICATION_CREDENTIALS",
        ].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        for (key, _) in saved { unsetenv(key) }

        do {
            _ = try GooglePlayMCP.makeClient()
            Issue.record("Expected makeClient to throw without credentials")
        } catch let error as GoogleAPIError {
            guard case .invalidConfiguration(let reason) = error else {
                Issue.record("Expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(reason.contains("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"))
        }
    }
}
