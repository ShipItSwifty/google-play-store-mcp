import Foundation
import GoogleAuthKit
import GooglePlayKit
import Logging
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The server's version, reported over MCP and by `--version`.
enum GooglePlayMCPVersion {
    static let current = "0.1.0"
}

/// MCP server exposing the Google Play Developer API — tracks and staged rollouts, uploaded
/// bundles and APKs, and recent user reviews, plus gated write tools for releasing and
/// controlling a rollout.
///
/// The server performs no analysis of its own; it is driven by an AI agent (the MCP host),
/// which calls these tools to gather state and reason about a release.
///
/// Credentials are read from the environment: `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (raw JSON),
/// `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`, or `GOOGLE_APPLICATION_CREDENTIALS`.
@main
struct GooglePlayMCP {
    static func main() async throws {
        switch CLIMode(arguments: CommandLine.arguments) {
        case .version:
            print(GooglePlayMCPVersion.current)
            return
        case .help:
            print(Self.usage)
            return
        case .serve:
            break
        }

        var log = Logger(label: "google-play-store-mcp")
        log.logLevel = .info

        let writesEnabled = PlayTools.writesEnabled()

        let server = Server(
            name: "google-play-store-mcp",
            version: GooglePlayMCPVersion.current,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: PlayTools.specs(writesEnabled: writesEnabled).map(\.tool))
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await PlayTools.call(
                    name: params.name,
                    arguments: params.arguments ?? [:],
                    writesEnabled: writesEnabled,
                    clientProvider: Self.makeClient
                )
            } catch let error as GoogleAPIError {
                return .init(content: [.plainText("Google Play error: \(error.localizedDescription)")], isError: true)
            } catch {
                return .init(content: [.plainText("Error: \(error.localizedDescription)")], isError: true)
            }
        }

        let transport = StdioTransport(logger: log)
        try await server.start(transport: transport)
        log.info(
            "google-play-store-mcp ready on stdio (writes \(writesEnabled ? "enabled" : "disabled"))")

        // Blocks while the transport runs the stdio read loop, and returns once the client closes
        // it — so the process exits with its host instead of lingering.
        await server.waitUntilCompleted()
    }

    /// Builds an authenticated client from the environment.
    ///
    /// Resolved per call rather than at startup so a credential problem is reported as a tool
    /// error the agent can read, instead of the server failing to launch with no visible reason.
    @Sendable
    static func makeClient() throws -> GooglePlayClient {
        guard let credentials = try GoogleServiceAccountCredentials.fromEnvironment() else {
            throw GoogleAPIError.invalidConfiguration(
                reason: """
                    No Google Play credentials found. Set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (raw JSON), \
                    GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH, or GOOGLE_APPLICATION_CREDENTIALS to a \
                    service account key with Play Developer API access.
                    """
            )
        }
        return GooglePlayClient(credentials: credentials)
    }

    static let usage = """
        google-play-store-mcp — MCP server for the Google Play Developer API
        (tracks, staged rollouts, uploaded bundles and APKs, user reviews).

        USAGE:
          google-play-store-mcp             Start the MCP server on stdio (default).
          google-play-store-mcp --version   Print the version and exit.
          google-play-store-mcp --help      Print this help and exit.

        Credentials are read from the environment, in priority order:
          GOOGLE_PLAY_SERVICE_ACCOUNT_JSON        Raw service account key JSON.
          GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH   Path to the key file.
          GOOGLE_APPLICATION_CREDENTIALS          Path to the key file (Google-wide convention).

        Optional: GOOGLE_PLAY_ENABLE_WRITES=1 additionally advertises the write tools
        (upload and release, update or halt a staged rollout, upload Data safety labels).
        Unset, every advertised tool is read-only.
        """
}

/// How the process was invoked.
enum CLIMode {
    case serve
    case version
    case help

    init(arguments: [String]) {
        let flags = Set(arguments.dropFirst())
        if !flags.isDisjoint(with: ["--version", "-v"]) {
            self = .version
        } else if !flags.isDisjoint(with: ["--help", "-h"]) {
            self = .help
        } else {
            self = .serve
        }
    }
}
