import Foundation
import GoogleAuthKit
import GooglePlayKit
import Synchronization
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

@Suite("Client caching")
struct CachedClientProviderTests {

    private static func stubClient() -> GooglePlayClient {
        GooglePlayClient(tokenProvider: { "test-token" }, session: .shared)
    }

    @Test("the client is resolved once and reused, so its token cache survives across calls")
    func resolvesOnce() throws {
        let resolutions = Mutex(0)
        let provider = CachedClientProvider {
            resolutions.withLock { $0 += 1 }
            return Self.stubClient()
        }

        _ = try provider.client()
        _ = try provider.client()
        _ = try provider.client()

        #expect(resolutions.withLock { $0 } == 1)
    }

    @Test("a failed resolution is not cached, so fixing credentials needs no restart")
    func failureIsRetried() throws {
        let attempts = Mutex(0)
        let provider = CachedClientProvider {
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            guard attempt > 1 else {
                throw GoogleAPIError.invalidConfiguration(reason: "no credentials yet")
            }
            return Self.stubClient()
        }

        #expect(throws: GoogleAPIError.self) { _ = try provider.client() }
        _ = try provider.client()
        _ = try provider.client()

        #expect(attempts.withLock { $0 } == 2)
    }
}

@Suite("Server instructions")
struct ServerInstructionsTests {

    @Test("instructions point the agent at the overview tool and state the write gate")
    func instructionsReflectWriteGate() {
        let readOnly = GooglePlayMCP.instructions(writesEnabled: false)
        #expect(readOnly.contains("play_release_overview"))
        #expect(readOnly.contains("disabled"))

        let writable = GooglePlayMCP.instructions(writesEnabled: true)
        #expect(writable.contains("ENABLED"))
        #expect(writable.contains("userFraction"))
    }

    @Test("every tool the instructions name exists in the catalog")
    func instructionsNameRealTools() {
        let names = Set(PlayTools.allSpecs.map(\.name))
        for writesEnabled in [false, true] {
            let text = GooglePlayMCP.instructions(writesEnabled: writesEnabled)
            let mentioned = text.split(whereSeparator: { !$0.isLetter && $0 != "_" })
                .map(String.init)
                .filter { $0.hasPrefix("play_") }
            for tool in mentioned {
                #expect(names.contains(tool), "instructions mention unknown tool \(tool)")
            }
        }
    }
}
