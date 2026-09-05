import Foundation
import GoogleAuthKit
import GooglePlayKit
import MCP
import Synchronization
import Testing

@testable import GooglePlayMCPServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` answering every request from one closure, keyed per session so parallel
/// suites cannot steal each other's responses.
final class ToolMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: String)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()
    static let sessionHeader = "X-Mock-Session-ID"

    static func register(sessionID: String, handler: @escaping Handler) {
        lock.withLock { handlers[sessionID] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader) ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[sessionID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mock = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: mock.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(mock.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A client provider backed by a mocked session, so a tool handler can be driven end to end.
private func stubClientProvider(
    handler: @escaping ToolMockURLProtocol.Handler
) -> PlayTools.ClientProvider {
    let sessionID = UUID().uuidString
    ToolMockURLProtocol.register(sessionID: sessionID, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ToolMockURLProtocol.self]
    configuration.httpAdditionalHeaders = [ToolMockURLProtocol.sessionHeader: sessionID]
    let session = URLSession(configuration: configuration)
    return { GooglePlayClient(tokenProvider: { "test-token" }, session: session) }
}

/// The text of a tool result, for asserting on what the agent actually sees.
private func text(of result: CallTool.Result) throws -> String {
    let content = try #require(result.content.first)
    guard case .text(let value, _, _) = content else {
        throw GoogleAPIError.invalidConfiguration(reason: "expected a text content block")
    }
    return value
}

@Suite("MCP tool handlers")
struct PlayToolHandlerTests {

    @Test("play_list_tracks renders the live release and rollout percentage")
    func listTracksHandler() async throws {
        let provider = stubClientProvider { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return (200, #"{"id":"e1"}"#) }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (
                200,
                #"{"tracks":[{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.25}]}]}"#
            )
        }

        let result = try await PlayTools.call(
            name: "play_list_tracks",
            arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false,
            clientProvider: provider
        )

        let output = try text(of: result)
        #expect(output.contains("production: inProgress"))
        #expect(output.contains("rollout=25%"))
    }

    @Test("play_get_track renders the requested track")
    func getTrackHandler() async throws {
        let provider = stubClientProvider { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return (200, #"{"id":"e1"}"#) }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (200, #"{"track":"beta","releases":[{"versionCodes":["9"],"status":"draft"}]}"#)
        }

        let result = try await PlayTools.call(
            name: "play_get_track",
            arguments: ["packageName": .string("com.example.app"), "track": .string("beta")],
            writesEnabled: false,
            clientProvider: provider
        )

        #expect(try text(of: result).contains("beta: draft"))
    }

    @Test("play_list_bundles and play_list_apks say so when nothing has been uploaded")
    func emptyArtifactListings() async throws {
        let provider = stubClientProvider { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return (200, #"{"id":"e1"}"#) }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (200, "{}")
        }

        let bundles = try await PlayTools.call(
            name: "play_list_bundles", arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false, clientProvider: provider)
        #expect(try text(of: bundles).contains("No bundles"))

        let apks = try await PlayTools.call(
            name: "play_list_apks", arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false, clientProvider: provider)
        #expect(try text(of: apks).contains("No APKs"))
    }

    @Test("play_list_bundles renders version codes when bundles exist")
    func bundleListing() async throws {
        let provider = stubClientProvider { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return (200, #"{"id":"e1"}"#) }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (200, #"{"bundles":[{"versionCode":412,"sha256":"abc"}]}"#)
        }

        let result = try await PlayTools.call(
            name: "play_list_bundles", arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false, clientProvider: provider)

        #expect(try text(of: result).contains("versionCode 412"))
    }

    @Test("play_list_reviews renders stars and text")
    func reviewsHandler() async throws {
        let provider = stubClientProvider { _ in
            (
                200,
                #"{"reviews":[{"reviewId":"r1","authorName":"Sam","comments":[{"userComment":{"text":"Great","starRating":5}}]}]}"#
            )
        }

        let result = try await PlayTools.call(
            name: "play_list_reviews",
            arguments: ["packageName": .string("com.example.app"), "maxResults": .int(5)],
            writesEnabled: false, clientProvider: provider)

        let output = try text(of: result)
        #expect(output.contains("Sam"))
        #expect(output.contains("Great"))
    }

    @Test("play_validate_edit reports success and leaves no edit behind")
    func validateEditHandler() async throws {
        let deleted = Mutex(false)
        let provider = stubClientProvider { request in
            if request.httpMethod == "DELETE" {
                deleted.withLock { $0 = true }
                return (204, "")
            }
            return (200, #"{"id":"e1"}"#)
        }

        let result = try await PlayTools.call(
            name: "play_validate_edit", arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false, clientProvider: provider)

        #expect(try text(of: result).contains("validated successfully"))
        #expect(deleted.withLock { $0 })
    }

    @Test("play_update_rollout commits the new fraction")
    func updateRolloutHandler() async throws {
        let provider = stubClientProvider { request in
            if request.httpMethod == "GET" {
                return (200, #"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.1}]}"#)
            }
            if request.httpMethod == "PUT" {
                return (200, #"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.5}]}"#)
            }
            return (200, #"{"id":"e1"}"#)
        }

        let result = try await PlayTools.call(
            name: "play_update_rollout",
            arguments: [
                "packageName": .string("com.example.app"),
                "track": .string("production"),
                "userFraction": .double(0.5),
            ],
            writesEnabled: true, clientProvider: provider)

        #expect(try text(of: result).contains("0.5"))
    }

    @Test("a numeric argument sent as a string is still accepted")
    func numericArgumentAsString() async throws {
        let provider = stubClientProvider { request in
            if request.httpMethod == "GET" {
                return (200, #"{"track":"production","releases":[{"versionCodes":["1"],"status":"inProgress"}]}"#)
            }
            if request.httpMethod == "PUT" { return (200, #"{"track":"production"}"#) }
            return (200, #"{"id":"e1"}"#)
        }

        // Some MCP hosts stringify numbers; a valid call should not fail on that alone.
        let result = try await PlayTools.call(
            name: "play_update_rollout",
            arguments: [
                "packageName": .string("com.example.app"),
                "track": .string("production"),
                "userFraction": .string("0.25"),
            ],
            writesEnabled: true, clientProvider: provider)

        #expect(try text(of: result).contains("0.25"))
    }

    @Test("play_halt_rollout reports the halt")
    func haltRolloutHandler() async throws {
        let provider = stubClientProvider { request in
            if request.httpMethod == "GET" {
                return (200, #"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.3}]}"#)
            }
            if request.httpMethod == "PUT" { return (200, #"{"track":"production"}"#) }
            return (200, #"{"id":"e1"}"#)
        }

        let result = try await PlayTools.call(
            name: "play_halt_rollout",
            arguments: ["packageName": .string("com.example.app"), "track": .string("production")],
            writesEnabled: true, clientProvider: provider)

        #expect(try text(of: result).contains("halted"))
    }

    @Test("play_upload_data_safety_labels warns that the result cannot be read back")
    func dataSafetyHandlerWarnsAboutVerification() async throws {
        let provider = stubClientProvider { _ in (200, "") }

        let result = try await PlayTools.call(
            name: "play_upload_data_safety_labels",
            arguments: [
                "packageName": .string("com.example.app"),
                "safetyLabelsCSV": .string("a,b\n1,2"),
            ],
            writesEnabled: true, clientProvider: provider)

        let output = try text(of: result)
        #expect(output.contains("Play Console"))
        #expect(output.contains("no confirmation"))
    }

    @Test("play_upload_and_release rejects an invalid status before uploading anything")
    func invalidStatusRejected() async throws {
        let provider = stubClientProvider { _ in (200, "{}") }

        do {
            _ = try await PlayTools.call(
                name: "play_upload_and_release",
                arguments: [
                    "packageName": .string("com.example.app"),
                    "track": .string("internal"),
                    "aabPath": .string("/nonexistent/app.aab"),
                    "status": .string("bogus"),
                ],
                writesEnabled: true, clientProvider: provider)
            Issue.record("Expected an invalid-status error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("bogus"))
        }
    }

    @Test("play_upload_and_release surfaces a missing artifact as a readable error")
    func missingArtifactSurfaces() async throws {
        let provider = stubClientProvider { _ in (200, #"{"id":"e1"}"#) }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await PlayTools.call(
                name: "play_upload_and_release",
                arguments: [
                    "packageName": .string("com.example.app"),
                    "track": .string("internal"),
                    "aabPath": .string("/nonexistent/app.aab"),
                ],
                writesEnabled: true, clientProvider: provider)
        }
    }
}

@Suite("CLI mode")
struct CLIModeTests {

    @Test(
        "flags select the mode",
        arguments: [
            (["prog"], CLIMode.serve),
            (["prog", "--version"], .version),
            (["prog", "-v"], .version),
            (["prog", "--help"], .help),
            (["prog", "-h"], .help),
        ])
    func parsesFlags(arguments: [String], expected: CLIMode) {
        #expect(CLIMode(arguments: arguments) == expected)
    }

    @Test("--version wins over --help so a version query is never swallowed by help")
    func versionTakesPrecedence() {
        #expect(CLIMode(arguments: ["prog", "--help", "--version"]) == .version)
    }
}
