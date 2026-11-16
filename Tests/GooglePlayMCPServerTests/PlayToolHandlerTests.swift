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
    nonisolated(unsafe) private static var latestSessionID: String?
    private static let lock = NSLock()
    static let sessionHeader = "X-Mock-Session-ID"

    static func register(sessionID: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[sessionID] = handler
            latestSessionID = sessionID
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // On Linux `httpAdditionalHeaders` is not reliably visible here, so fall back to the most
        // recently registered session. Sound only because this suite is `.serialized`.
        let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader) ?? ""
        let handler = Self.lock.withLock {
            Self.handlers[sessionID] ?? Self.latestSessionID.flatMap { Self.handlers[$0] }
        }
        guard let handler else {
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
    return {
        GooglePlayClient(
            tokenProvider: { "test-token" }, session: session,
            retryPolicy: GooglePlayRetryPolicy(maxAttempts: 3, baseDelay: .zero, maxDelay: .zero))
    }
}

/// The text of a tool result, for asserting on what the agent actually sees.
private func text(of result: CallTool.Result) throws -> String {
    let content = try #require(result.content.first)
    guard case .text(let value, _, _) = content else {
        throw GoogleAPIError.invalidConfiguration(reason: "expected a text content block")
    }
    return value
}

/// Decodes a result's `structuredContent` back into the payload type the tool promised.
private func structured<Output: Decodable>(_ type: Output.Type, of result: CallTool.Result) throws -> Output {
    let value = try #require(result.structuredContent)
    return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
}

@Suite("MCP tool handlers", .serialized)
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

        // The same data, exact and machine-readable.
        let payload = try structured(ToolOutput.Tracks.self, of: result)
        #expect(payload.packageName == "com.example.app")
        let release = try #require(payload.tracks.first?.releases?.first)
        #expect(release.userFraction == 0.25)
        #expect(release.versionCodes == ["412"])
    }

    @Test("play_release_overview renders tracks, bundles, and APKs together")
    func releaseOverviewHandler() async throws {
        let provider = stubClientProvider { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return (200, #"{"id":"e1"}"#) }
            if request.httpMethod == "DELETE" { return (204, "") }
            if path.hasSuffix("/tracks") {
                return (200, #"{"tracks":[{"track":"production","releases":[{"versionCodes":["412"],"status":"completed"}]}]}"#)
            }
            if path.hasSuffix("/bundles") { return (200, #"{"bundles":[{"versionCode":412}]}"#) }
            return (200, "{}")
        }

        let result = try await PlayTools.call(
            name: "play_release_overview",
            arguments: ["packageName": .string("com.example.app")],
            writesEnabled: false,
            clientProvider: provider
        )

        let output = try text(of: result)
        #expect(output.contains("production: completed"))
        #expect(output.contains("versionCode 412"))
        #expect(output.contains("No APKs"))

        let payload = try structured(ToolOutput.Overview.self, of: result)
        #expect(payload.bundles.map(\.versionCode) == [412])
        #expect(payload.apks.isEmpty)
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

        let payload = try structured(ToolOutput.Reviews.self, of: result)
        #expect(payload.reviews.map(\.reviewId) == ["r1"])
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

        // The structured result is the track as Play returned it after the commit.
        let payload = try structured(ToolOutput.Rollout.self, of: result)
        #expect(payload.track.releases?.first?.userFraction == 0.5)
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

        let payload = try structured(ToolOutput.DataSafetyUpload.self, of: result)
        #expect(payload.uploaded)
        #expect(!payload.verifiable)
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

    @Test("play_upload_and_release rejects a fraction paired with a completed release")
    func fractionWithCompletedRejectedViaMCP() async throws {
        let provider = stubClientProvider { _ in (200, #"{"id":"e1"}"#) }

        do {
            _ = try await PlayTools.call(
                name: "play_upload_and_release",
                arguments: [
                    "packageName": .string("com.example.app"),
                    "track": .string("production"),
                    "aabPath": .string("/nonexistent/app.aab"),
                    "status": .string("completed"),
                    "userFraction": .double(0.5),
                ],
                writesEnabled: true, clientProvider: provider)
            Issue.record("Expected the completed+fraction pairing to be rejected")
        } catch let error as GoogleAPIError {
            // The agent must be told why, not just that it failed — otherwise it retries blindly.
            #expect(error.localizedDescription.contains("staged"))
        }
    }

    @Test("play_upload_and_release rejects an inProgress release with no fraction")
    func stagedWithoutFractionRejectedViaMCP() async throws {
        let provider = stubClientProvider { _ in (200, #"{"id":"e1"}"#) }

        do {
            _ = try await PlayTools.call(
                name: "play_upload_and_release",
                arguments: [
                    "packageName": .string("com.example.app"),
                    "track": .string("production"),
                    "aabPath": .string("/nonexistent/app.aab"),
                    "status": .string("inProgress"),
                ],
                writesEnabled: true, clientProvider: provider)
            Issue.record("Expected a staged release with no fraction to be rejected")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("userFraction"))
        }
    }

    @Test("play_update_rollout rejects a boundary fraction with an actionable message")
    func boundaryFractionRejectedViaMCP() async throws {
        let provider = stubClientProvider { _ in (200, #"{"id":"e1"}"#) }

        do {
            _ = try await PlayTools.call(
                name: "play_update_rollout",
                arguments: [
                    "packageName": .string("com.example.app"),
                    "track": .string("production"),
                    "userFraction": .double(1.0),
                ],
                writesEnabled: true, clientProvider: provider)
            Issue.record("Expected 1.0 to be rejected as out of Play's exclusive range")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("completed"))
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

/// The request body, read from the stream URLSession turns it into before a protocol sees it.
private func bodyText(_ request: URLRequest) -> String? {
    if let body = request.httpBody { return String(data: body, encoding: .utf8) }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(data: data, encoding: .utf8)
}

/// Requests seen by a stub provider, so a handler test can assert on what reached Play.
private final class RequestLog: Sendable {
    private let entries = Mutex<[(method: String, path: String, query: String?, body: String?)]>([])

    func record(_ request: URLRequest) {
        let body = bodyText(request)
        entries.withLock { $0.append((request.httpMethod ?? "GET", request.url?.path ?? "", request.url?.query, body)) }
    }

    var all: [(method: String, path: String, query: String?, body: String?)] { entries.withLock { $0 } }
}

private let haltedProduction = #"{"track":"production","releases":[{"versionCodes":["412"],"status":"halted","userFraction":0.3}]}"#

/// Serves `tracks` by name, creates and commits edits, and echoes PUT bodies.
private func trackProvider(_ tracks: [String: String], log: RequestLog) -> PlayTools.ClientProvider {
    stubClientProvider { request in
        log.record(request)
        let path = request.url?.path ?? ""
        switch request.httpMethod {
        case "GET":
            let name = String(path.split(separator: "/").last ?? "")
            return tracks[name].map { (200, $0) } ?? (404, "{}")
        case "PUT":
            return (200, bodyText(request) ?? "{}")
        case "DELETE":
            return (204, "")
        default:
            return (200, #"{"id":"e1"}"#)
        }
    }
}

@Suite("MCP write tools", .serialized)
struct PlayWriteToolHandlerTests {

    @Test("write tools commit with errorIfInReview unless told otherwise")
    func commitDefaultsToErrorIfInReview() async throws {
        let log = RequestLog()
        _ = try await PlayTools.call(
            name: "play_resume_rollout",
            arguments: ["packageName": .string("com.example.app"), "track": .string("production")],
            writesEnabled: true, clientProvider: trackProvider(["production": haltedProduction], log: log))

        let commit = try #require(log.all.first { $0.path.hasSuffix(":commit") })
        #expect(commit.query == "changesInReviewBehavior=ERROR_IF_IN_REVIEW")
    }

    @Test("an explicit cancelInReviewAndSubmit and changesNotSentForReview reach the commit")
    func commitOptionsPassThrough() async throws {
        let log = RequestLog()
        _ = try await PlayTools.call(
            name: "play_resume_rollout",
            arguments: [
                "packageName": .string("com.example.app"), "track": .string("production"),
                "changesInReviewBehavior": .string("cancelInReviewAndSubmit"),
                "changesNotSentForReview": .bool(true),
            ],
            writesEnabled: true, clientProvider: trackProvider(["production": haltedProduction], log: log))

        let commit = try #require(log.all.first { $0.path.hasSuffix(":commit") })
        #expect(commit.query == "changesNotSentForReview=true&changesInReviewBehavior=CANCEL_IN_REVIEW_AND_SUBMIT")
    }

    @Test("an unknown changesInReviewBehavior fails before any request")
    func invalidCommitBehavior() async throws {
        let log = RequestLog()
        await #expect(throws: GoogleAPIError.self) {
            _ = try await PlayTools.call(
                name: "play_halt_rollout",
                arguments: [
                    "packageName": .string("com.example.app"), "track": .string("production"),
                    "changesInReviewBehavior": .string("ignore"),
                ],
                writesEnabled: true, clientProvider: trackProvider([:], log: log))
        }
        #expect(log.all.isEmpty)
    }

    @Test("play_resume_rollout reports the resumed track")
    func resumeRolloutHandler() async throws {
        let log = RequestLog()
        let result = try await PlayTools.call(
            name: "play_resume_rollout",
            arguments: ["packageName": .string("com.example.app"), "track": .string("production")],
            writesEnabled: true, clientProvider: trackProvider(["production": haltedProduction], log: log))

        #expect(try text(of: result).contains("rollout=30%"))
        let payload = try structured(ToolOutput.Rollout.self, of: result)
        #expect(payload.track.releases?.first?.status == .inProgress)
    }

    @Test("play_complete_rollout reports the completed track")
    func completeRolloutHandler() async throws {
        let log = RequestLog()
        let result = try await PlayTools.call(
            name: "play_complete_rollout",
            arguments: ["packageName": .string("com.example.app"), "track": .string("production")],
            writesEnabled: true, clientProvider: trackProvider(["production": haltedProduction], log: log))

        #expect(try text(of: result).contains("production: completed"))
        let payload = try structured(ToolOutput.Rollout.self, of: result)
        #expect(payload.track.releases?.first?.userFraction == nil)
    }

    @Test("play_promote_release promotes the given version codes to the target track")
    func promoteReleaseHandler() async throws {
        let log = RequestLog()
        let tracks = [
            "internal": #"{"track":"internal","releases":[{"versionCodes":["413"],"status":"completed"}]}"#,
            "production": #"{"track":"production","releases":[]}"#,
        ]
        let result = try await PlayTools.call(
            name: "play_promote_release",
            arguments: [
                "packageName": .string("com.example.app"),
                "fromTrack": .string("internal"), "toTrack": .string("production"),
                "versionCodes": .array([.int(413)]),
            ],
            writesEnabled: true, clientProvider: trackProvider(tracks, log: log))

        #expect(try text(of: result).contains("versionCodes=[413]"))
        let put = try #require(log.all.first { $0.method == "PUT" })
        #expect(put.path.hasSuffix("/tracks/production"))
    }

    @Test("play_reply_to_review posts the reply and returns what Play applied")
    func replyHandler() async throws {
        let log = RequestLog()
        let provider = stubClientProvider { request in
            log.record(request)
            return (200, #"{"result":{"replyText":"Thanks for the report","lastEdited":{"seconds":"1700000000"}}}"#)
        }
        let result = try await PlayTools.call(
            name: "play_reply_to_review",
            arguments: [
                "packageName": .string("com.example.app"), "reviewId": .string("gp:abc"),
                "replyText": .string("Thanks for the report"),
            ],
            writesEnabled: true, clientProvider: provider)

        #expect(try text(of: result).contains("Thanks for the report"))
        #expect(log.all.first?.path.hasSuffix("/reviews/gp:abc:reply") == true)
        #expect(try structured(ToolOutput.Reply.self, of: result).reviewId == "gp:abc")
    }

    @Test("an unparseable userFraction fails the release instead of shipping to everyone")
    func malformedFractionFailsRelease() async throws {
        let log = RequestLog()
        do {
            _ = try await PlayTools.call(
                name: "play_upload_and_release",
                arguments: [
                    "packageName": .string("com.example.app"), "track": .string("production"),
                    "aabPath": .string("/tmp/app.aab"), "userFraction": .string("10%"),
                ],
                writesEnabled: true, clientProvider: trackProvider([:], log: log))
            Issue.record("Expected a malformed userFraction to be rejected")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("userFraction"))
        }
        #expect(log.all.isEmpty)
    }

    @Test("play_list_reviews filters by stars and shows each review's id")
    func filteredReviewsHandler() async throws {
        let provider = stubClientProvider { _ in
            (
                200,
                #"{"reviews":[{"reviewId":"good","comments":[{"userComment":{"text":"Great","starRating":5}}]},{"reviewId":"bad","comments":[{"userComment":{"text":"Crashes","starRating":1,"lastModified":{"seconds":"1700000000"}}}]}]}"#
            )
        }
        let result = try await PlayTools.call(
            name: "play_list_reviews",
            arguments: ["packageName": .string("com.example.app"), "maxStars": .int(2)],
            writesEnabled: false, clientProvider: provider)

        let rendered = try text(of: result)
        #expect(rendered.contains("[bad]"))
        #expect(rendered.contains("2023-11-14"))
        #expect(!rendered.contains("[good]"))
    }

    @Test("limit keeps only the newest bundles")
    func artifactLimit() async throws {
        let provider = stubClientProvider { request in
            if request.httpMethod == "GET" {
                return (200, #"{"bundles":[{"versionCode":3},{"versionCode":1},{"versionCode":2}]}"#)
            }
            if request.httpMethod == "DELETE" { return (204, "") }
            return (200, #"{"id":"e1"}"#)
        }
        let result = try await PlayTools.call(
            name: "play_list_bundles",
            arguments: ["packageName": .string("com.example.app"), "limit": .int(2)],
            writesEnabled: false, clientProvider: provider)

        let payload = try structured(ToolOutput.Bundles.self, of: result)
        #expect(payload.bundles.map(\.versionCode) == [2, 3])
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
