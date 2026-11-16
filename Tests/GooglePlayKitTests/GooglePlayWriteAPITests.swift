import Foundation
import GoogleAuthKit
import Synchronization
import Testing

@testable import GooglePlayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func makeClient(
    retryPolicy: GooglePlayRetryPolicy = .immediate,
    handler: @escaping MockURLProtocol.Handler
) -> (client: GooglePlayClient, sessionID: String) {
    let (session, sessionID) = makeMockSession(handler: handler)
    return (GooglePlayClient(tokenProvider: { "test-token" }, session: session, retryPolicy: retryPolicy), sessionID)
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

/// Answers edit create/commit/delete, serves `tracks` by name on GET, and echoes PUT bodies.
private func trackServer(
    _ tracks: [String: String],
    commitStatus: Int = 200
) -> MockURLProtocol.Handler {
    { request in
        let path = request.url?.path ?? ""
        switch request.httpMethod {
        case "POST" where path.hasSuffix("/edits"):
            return .json(#"{"id":"edit-w"}"#)
        case "POST" where path.hasSuffix(":commit"):
            return commitStatus == 200 ? .json(#"{"id":"edit-w"}"#) : .error(statusCode: commitStatus, body: "in review")
        case "DELETE":
            return .empty()
        case "GET":
            let name = String(path.split(separator: "/").last ?? "")
            return tracks[name].map { .json($0) } ?? .error(statusCode: 404, body: "no track \(name)")
        case "PUT":
            return .json(bodyText(request) ?? "{}")
        default:
            return .error(statusCode: 404, body: "unexpected")
        }
    }
}

/// The release list sent in the one PUT a rollout change makes.
private func sentReleases(_ sessionID: String) throws -> [GooglePlayRelease] {
    let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
    let track = try JSONDecoder().decode(GooglePlayTrack.self, from: try #require(put.body))
    return track.releases ?? []
}

private let stagedTrack = """
    {"track":"production","releases":[
      {"versionCodes":["410"],"status":"completed","name":"4.1.0"},
      {"versionCodes":["412"],"status":"inProgress","userFraction":0.2,"name":"4.2.0"},
      {"status":"draft","name":"4.3.0 draft"}
    ]}
    """

private let haltedTrack = """
    {"track":"production","releases":[
      {"versionCodes":["410"],"status":"completed"},
      {"versionCodes":["412"],"status":"halted","userFraction":0.3}
    ]}
    """

@Suite("Google Play retries", .serialized)
struct GooglePlayRetryTests {

    @Test("a GET that fails transiently is retried and succeeds")
    func transientGetRetried() async throws {
        let attempts = Mutex(0)
        let (client, sessionID) = makeClient { _ in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            return attempt == 1 ? .error(statusCode: 503) : .json(#"{"track":"internal"}"#)
        }
        let track: GooglePlayTrack = try await client.get("/applications/a/edits/e/tracks/internal")
        #expect(track.track == "internal")
        #expect(MockURLProtocol.requests(for: sessionID).count == 2)
    }

    @Test("a transport failure on a GET is retried")
    func transportFailureRetried() async throws {
        let attempts = Mutex(0)
        let (client, sessionID) = makeClient { _ in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            return attempt == 1 ? .failure() : .json(#"{"track":"internal"}"#)
        }
        let _: GooglePlayTrack = try await client.get("/x")
        #expect(MockURLProtocol.requests(for: sessionID).count == 2)
    }

    @Test("a POST is never retried, since creating or committing an edit twice is not safe")
    func postNotRetried() async throws {
        let (client, sessionID) = makeClient { _ in .error(statusCode: 503) }
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.createEdit(packageName: "com.example.app")
        }
        #expect(MockURLProtocol.requests(for: sessionID).count == 1)
    }

    @Test("a client error is not retried", arguments: [400, 401, 403, 404, 409])
    func clientErrorNotRetried(status: Int) async throws {
        let (client, sessionID) = makeClient { _ in .error(statusCode: status) }
        await #expect(throws: GoogleAPIError.self) {
            let _: GooglePlayTrack = try await client.get("/x")
        }
        #expect(MockURLProtocol.requests(for: sessionID).count == 1)
    }

    @Test("the none policy sends a request exactly once")
    func noRetryPolicy() async throws {
        let (client, sessionID) = makeClient(retryPolicy: .none) { _ in .error(statusCode: 503) }
        await #expect(throws: GoogleAPIError.self) {
            let _: GooglePlayTrack = try await client.get("/x")
        }
        #expect(MockURLProtocol.requests(for: sessionID).count == 1)
    }

    @Test("a DELETE that 404s on retry succeeded on an earlier attempt")
    func deleteNotFoundOnRetryIsSuccess() async throws {
        let attempts = Mutex(0)
        let (client, sessionID) = makeClient { _ in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            return attempt == 1 ? .failure() : .error(statusCode: 404)
        }
        try await client.deleteEdit(packageName: "com.example.app", editId: "e")
        #expect(MockURLProtocol.requests(for: sessionID).count == 2)
    }

    @Test("a DELETE that 404s on its first attempt still fails")
    func deleteNotFoundFirstTimeFails() async throws {
        let (client, _) = makeClient { _ in .error(statusCode: 404) }
        await #expect(throws: GoogleAPIError.self) {
            try await client.deleteEdit(packageName: "com.example.app", editId: "e")
        }
    }

    @Test("the delay grows, honours Retry-After, and never exceeds the cap")
    func delaySchedule() {
        let policy = GooglePlayRetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(5))
        let first = policy.delay(afterAttempt: 1, retryAfter: nil)
        let second = policy.delay(afterAttempt: 2, retryAfter: nil)
        #expect(first >= .seconds(1) && first <= .milliseconds(1250))
        #expect(second >= .seconds(2) && second <= .milliseconds(2500))
        #expect(policy.delay(afterAttempt: 10, retryAfter: nil) == .seconds(5))
        #expect(policy.delay(afterAttempt: 1, retryAfter: "3") == .seconds(3))
        #expect(policy.delay(afterAttempt: 1, retryAfter: "120") == .seconds(5))
    }

    @Test("only transport failures, 408, 429, and retryable 5xx are transient")
    func transientClassification() {
        for status in [0, 408, 429, 500, 502, 503, 504] {
            #expect(GooglePlayRetryPolicy.isTransient(.apiError(statusCode: status, body: "")))
        }
        for status in [400, 403, 404, 501] {
            #expect(!GooglePlayRetryPolicy.isTransient(.apiError(statusCode: status, body: "")))
        }
        #expect(!GooglePlayRetryPolicy.isTransient(.invalidConfiguration(reason: "")))
    }
}

@Suite("Google Play rollout control", .serialized)
struct GooglePlayRolloutControlTests {

    @Test("commit options become Play's query parameters")
    func commitOptionsQuery() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"id":"e"}"#) }
        try await client.commitEdit(
            packageName: "com.example.app", editId: "e",
            options: GooglePlayCommitOptions(changesNotSentForReview: true, changesInReviewBehavior: .errorIfInReview))
        let commit = try #require(MockURLProtocol.requests(for: sessionID).first)
        #expect(commit.path.hasSuffix("/edits/e:commit"))
        #expect(commit.query == "changesNotSentForReview=true&changesInReviewBehavior=ERROR_IF_IN_REVIEW")
    }

    @Test("the default commit sends no query, keeping Play's own behaviour")
    func defaultCommitHasNoQuery() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"id":"e"}"#) }
        try await client.commitEdit(packageName: "com.example.app", editId: "e")
        #expect(MockURLProtocol.requests(for: sessionID).first?.query == nil)
    }

    @Test("resumeRollout restarts a halted release at its recorded fraction")
    func resumeAtRecordedFraction() async throws {
        let (client, sessionID) = makeClient(handler: trackServer(["production": haltedTrack]))
        try await client.resumeRollout(packageName: "com.example.app", track: "production")

        let releases = try sentReleases(sessionID)
        #expect(releases.count == 2)
        let resumed = try #require(releases.first { $0.versionCodes == ["412"] })
        #expect(resumed.status == .inProgress)
        #expect(resumed.userFraction == 0.3)
        #expect(releases.contains { $0.status == .completed && $0.versionCodes == ["410"] })
        #expect(MockURLProtocol.requests(for: sessionID).contains { $0.path.hasSuffix(":commit") })
    }

    @Test("resumeRollout can resume at a new fraction")
    func resumeAtNewFraction() async throws {
        let (client, sessionID) = makeClient(handler: trackServer(["production": haltedTrack]))
        try await client.resumeRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
        #expect(try sentReleases(sessionID).first { $0.versionCodes == ["412"] }?.userFraction == 0.5)
    }

    @Test("resumeRollout fails, and deletes its edit, when the halted release records no fraction")
    func resumeWithoutFractionFails() async throws {
        let track = #"{"track":"production","releases":[{"versionCodes":["412"],"status":"halted"}]}"#
        let (client, sessionID) = makeClient(handler: trackServer(["production": track]))
        await #expect(throws: GoogleAPIError.self) {
            try await client.resumeRollout(packageName: "com.example.app", track: "production")
        }
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(!requests.contains { $0.method == "PUT" || $0.path.hasSuffix(":commit") })
        #expect(requests.contains { $0.method == "DELETE" })
    }

    @Test("resumeRollout refuses a track with nothing halted")
    func resumeNeedsHaltedRelease() async throws {
        let (client, _) = makeClient(handler: trackServer(["production": stagedTrack]))
        await #expect(throws: GoogleAPIError.self) {
            try await client.resumeRollout(packageName: "com.example.app", track: "production")
        }
    }

    @Test("completeRollout completes the staged release, drops the one it supersedes, and keeps drafts")
    func completeStagedRelease() async throws {
        let (client, sessionID) = makeClient(handler: trackServer(["production": stagedTrack]))
        try await client.completeRollout(packageName: "com.example.app", track: "production")

        let releases = try sentReleases(sessionID)
        #expect(releases.count == 2)
        let completed = try #require(releases.first { $0.status == .completed })
        #expect(completed.versionCodes == ["412"])
        #expect(completed.userFraction == nil)
        #expect(completed.name == "4.2.0")
        #expect(releases.contains { $0.status == .draft })
        #expect(!releases.contains { $0.versionCodes == ["410"] })
    }

    @Test("completeRollout also completes a halted release")
    func completeHaltedRelease() async throws {
        let (client, sessionID) = makeClient(handler: trackServer(["production": haltedTrack]))
        try await client.completeRollout(packageName: "com.example.app", track: "production")
        let releases = try sentReleases(sessionID)
        #expect(releases.count == 1)
        #expect(releases.first?.status == .completed)
        #expect(releases.first?.versionCodes == ["412"])
    }

    @Test("a commit Play rejects deletes the edit and surfaces Play's error")
    func rejectedCommitCleansUp() async throws {
        let (client, sessionID) = makeClient(handler: trackServer(["production": stagedTrack], commitStatus: 400))
        await #expect(throws: GoogleAPIError.self) {
            try await client.completeRollout(
                packageName: "com.example.app", track: "production",
                commitOptions: GooglePlayCommitOptions(changesInReviewBehavior: .errorIfInReview))
        }
        #expect(MockURLProtocol.requests(for: sessionID).contains { $0.method == "DELETE" })
    }
}

@Suite("Google Play promotion", .serialized)
struct GooglePlayPromotionTests {

    private let internalTrack = """
        {"track":"internal","releases":[
          {"versionCodes":["413"],"status":"completed","name":"4.3.0",
           "releaseNotes":[{"language":"en-US","text":"New sync"}]}
        ]}
        """

    @Test("promotion copies the source's completed release, with its name and notes, to the target")
    func promotesCompletedRelease() async throws {
        let (client, sessionID) = makeClient(
            handler: trackServer(["internal": internalTrack, "production": stagedTrack]))
        try await client.promoteRelease(packageName: "com.example.app", fromTrack: "internal", toTrack: "production")

        let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
        #expect(put.path.hasSuffix("/tracks/production"))
        let releases = try sentReleases(sessionID)
        let promoted = try #require(releases.first { $0.versionCodes == ["413"] })
        #expect(promoted.status == .completed)
        #expect(promoted.name == "4.3.0")
        #expect(promoted.releaseNotes?.first?.text == "New sync")
        // A completed promotion supersedes the completed and staged releases but keeps the draft.
        #expect(releases.count == 2)
        #expect(releases.contains { $0.status == .draft })
        #expect(MockURLProtocol.requests(for: sessionID).contains { $0.path.hasSuffix(":commit") })
    }

    @Test("a staged promotion keeps the target's completed release and replaces its staged one")
    func stagedPromotionKeepsCompleted() async throws {
        let (client, sessionID) = makeClient(
            handler: trackServer(["internal": internalTrack, "production": stagedTrack]))
        try await client.promoteRelease(
            packageName: "com.example.app", fromTrack: "internal", toTrack: "production",
            status: .inProgress, userFraction: 0.05)

        let releases = try sentReleases(sessionID)
        #expect(releases.contains { $0.status == .completed && $0.versionCodes == ["410"] })
        #expect(!releases.contains { $0.versionCodes == ["412"] })
        let staged = try #require(releases.first { $0.versionCodes == ["413"] })
        #expect(staged.status == .inProgress)
        #expect(staged.userFraction == 0.05)
    }

    @Test("version codes that are not on the source track are refused, and the edit is deleted")
    func unknownVersionCodesRefused() async throws {
        let (client, sessionID) = makeClient(
            handler: trackServer(["internal": internalTrack, "production": stagedTrack]))
        await #expect(throws: GoogleAPIError.self) {
            try await client.promoteRelease(
                packageName: "com.example.app", fromTrack: "internal", toTrack: "production", versionCodes: ["999"])
        }
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(!requests.contains { $0.method == "PUT" })
        #expect(requests.contains { $0.method == "DELETE" })
    }

    @Test(
        "invalid promotions fail before any request",
        arguments: [
            ("production", GooglePlayReleaseStatus.completed, 0.5), ("internal", .completed, 0.5), ("production", .inProgress, nil),
        ] as [(String, GooglePlayReleaseStatus, Double?)])
    func invalidPromotionFailsLocally(toTrack: String, status: GooglePlayReleaseStatus, fraction: Double?) async throws {
        let (client, sessionID) = makeClient { _ in .error(statusCode: 500) }
        await #expect(throws: GoogleAPIError.self) {
            try await client.promoteRelease(
                packageName: "com.example.app", fromTrack: "internal", toTrack: toTrack,
                status: status, userFraction: fraction)
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty)
    }

    @Test("with no version codes given, completed beats in-progress, and the newest wins")
    func sourceSelection() throws {
        let releases = [
            GooglePlayRelease(versionCodes: ["9"], status: .inProgress, userFraction: 0.1),
            GooglePlayRelease(versionCodes: ["5"], status: .completed),
            GooglePlayRelease(versionCodes: ["7"], status: .completed),
            GooglePlayRelease(status: .draft),
        ]
        #expect(try GooglePlayClient.promotionSource(in: releases, track: "t", versionCodes: nil).versionCodes == ["7"])
        let staged = Array(releases.prefix(1))
        #expect(try GooglePlayClient.promotionSource(in: staged, track: "t", versionCodes: nil).versionCodes == ["9"])
        #expect(throws: GoogleAPIError.self) {
            _ = try GooglePlayClient.promotionSource(in: [GooglePlayRelease(status: .draft)], track: "t", versionCodes: nil)
        }
    }
}

@Suite("Google Play reviews: filtering and replies", .serialized)
struct GooglePlayReviewWriteTests {

    private static func review(_ id: String, stars: Int) -> String {
        #"{"reviewId":"\#(id)","comments":[{"userComment":{"text":"t","starRating":\#(stars)}}]}"#
    }

    @Test("a filtered listing keeps paging past misses until it has enough matches")
    func filterPagesPastMisses() async throws {
        let (client, sessionID) = makeClient { request in
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value
            switch token {
            case nil:
                return .json(
                    #"{"reviews":[\#(Self.review("a", stars: 5)),\#(Self.review("b", stars: 1))],"tokenPagination":{"nextPageToken":"p2"}}"#
                )
            default:
                return .json(#"{"reviews":[\#(Self.review("c", stars: 5)),\#(Self.review("d", stars: 2))]}"#)
            }
        }
        let reviews = try await client.listReviews(packageName: "com.example.app", maxResults: 2) {
            ($0.latestUserComment?.starRating ?? 0) <= 2
        }
        #expect(reviews.map(\.reviewId) == ["b", "d"])
        #expect(MockURLProtocol.requests(for: sessionID).count == 2)
        // Filtered pages ask for full pages, not just the matches still needed.
        #expect(MockURLProtocol.requests(for: sessionID).first?.query?.contains("maxResults=100") == true)
    }

    @Test("the scan limit stops paging even when matches are short")
    func scanLimitStopsPaging() async throws {
        let (client, sessionID) = makeClient { _ in
            .json(#"{"reviews":[\#(Self.review("a", stars: 5))],"tokenPagination":{"nextPageToken":"\#(UUID().uuidString)"}}"#)
        }
        let reviews = try await client.listReviews(packageName: "com.example.app", maxResults: 10, scanLimit: 3) {
            $0.latestUserComment?.starRating == 1
        }
        #expect(reviews.isEmpty)
        #expect(MockURLProtocol.requests(for: sessionID).count == 3)
    }

    @Test("replyToReview posts the trimmed text to the review's :reply endpoint")
    func replyPostsText() async throws {
        let (client, sessionID) = makeClient { _ in
            .json(#"{"result":{"replyText":"Thanks!","lastEdited":{"seconds":"1700000000","nanos":0}}}"#)
        }
        let result = try await client.replyToReview(
            packageName: "com.example.app", reviewId: "gp:AOq-1_x", replyText: "  Thanks!  ")
        #expect(result.replyText == "Thanks!")
        #expect(result.lastEdited?.date == Date(timeIntervalSince1970: 1_700_000_000))

        let request = try #require(MockURLProtocol.requests(for: sessionID).first)
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/reviews/gp:AOq-1_x:reply"))
        let body = try #require(request.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == #"{"replyText":"Thanks!"}"#)
    }

    @Test("replies that are empty or over Play's limit fail before any request", arguments: ["   ", String(repeating: "x", count: 351)])
    func replyValidation(text: String) async throws {
        let (client, sessionID) = makeClient { _ in .json("{}") }
        await #expect(throws: GoogleAPIError.self) {
            try await client.replyToReview(packageName: "com.example.app", reviewId: "r", replyText: text)
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty)
    }

    @Test("review metadata Play returns is decoded")
    func reviewMetadataDecodes() throws {
        let json = """
            {"reviewId":"r","comments":[
              {"userComment":{"text":"Crashes","originalText":"Stürzt ab","starRating":1,
                "lastModified":{"seconds":"1700000000","nanos":500000000},"androidOsVersion":34,
                "appVersionCode":412,"thumbsUpCount":3,"thumbsDownCount":1,
                "deviceMetadata":{"productName":"Pixel 8","manufacturer":"Google","ramMb":8192}}},
              {"developerComment":{"text":"Fixed in 4.2.1","lastModified":{"seconds":"1700001000"}}}
            ]}
            """
        let review = try JSONDecoder().decode(GooglePlayReview.self, from: Data(json.utf8))
        let user = try #require(review.latestUserComment)
        #expect(user.originalText == "Stürzt ab")
        #expect(user.androidOsVersion == 34)
        #expect(user.thumbsUpCount == 3)
        #expect(user.deviceMetadata?.productName == "Pixel 8")
        #expect(user.lastModified?.date == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(review.latestDeveloperComment?.text == "Fixed in 4.2.1")
        #expect(GooglePlayTimestamp(seconds: "not-a-number").date == nil)
    }
}
