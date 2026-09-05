import Foundation
import GoogleAuthKit
import Testing

@testable import GooglePlayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a client backed by a mock session and a canned token, skipping RSA signing and OAuth2.
private func makeClient(
    handler: @escaping MockURLProtocol.Handler
) -> (client: GooglePlayClient, sessionID: String) {
    let (session, sessionID) = makeMockSession(handler: handler)
    return (GooglePlayClient(tokenProvider: { "test-token" }, session: session), sessionID)
}

private let tracksJSON = """
    {"tracks":[
      {"track":"production","releases":[
        {"name":"4.2.0","versionCodes":["412"],"status":"inProgress","userFraction":0.25,
         "releaseNotes":[{"language":"en-US","text":"Faster sync"}]}
      ]},
      {"track":"internal","releases":[{"versionCodes":["413"],"status":"completed"}]}
    ]}
    """

@Suite("Google Play read API", .serialized)
struct GooglePlayReadAPITests {

    @Test("listTracks creates an edit, reads tracks, and deletes the edit")
    func listTracksUsesAThrowawayEdit() async throws {
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") {
                return .json(#"{"id":"edit-1","expiryTimeSeconds":"1700000000"}"#)
            }
            if request.httpMethod == "GET", path.hasSuffix("/tracks") {
                return .json(tracksJSON)
            }
            if request.httpMethod == "DELETE" {
                return .empty()
            }
            return .error(statusCode: 404, body: "unexpected \(request.httpMethod ?? "") \(path)")
        }

        let tracks = try await client.listTracks(packageName: "com.example.app")

        #expect(tracks.count == 2)
        let production = try #require(tracks.first { $0.track == "production" })
        let release = try #require(production.releases?.first)
        #expect(release.status == .inProgress)
        #expect(release.userFraction == 0.25)
        #expect(release.versionCodes == ["412"])

        // The edit must be created and then deleted — never committed.
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.contains { $0.method == "POST" && $0.path.hasSuffix("/edits") })
        #expect(requests.contains { $0.method == "DELETE" && $0.path.hasSuffix("/edits/edit-1") })
        #expect(!requests.contains { $0.path.contains(":commit") })
    }

    @Test("withReadOnlyEdit deletes the edit even when the read throws")
    func readOnlyEditCleansUpOnFailure() async throws {
        let (client, sessionID) = makeClient { request in
            if request.httpMethod == "POST", request.url?.path.hasSuffix("/edits") == true {
                return .json(#"{"id":"edit-2"}"#)
            }
            if request.httpMethod == "DELETE" { return .empty() }
            return .error(statusCode: 500, body: #"{"error":{"code":500,"message":"boom"}}"#)
        }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.listTracks(packageName: "com.example.app")
        }

        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.contains { $0.method == "DELETE" && $0.path.hasSuffix("/edits/edit-2") })
    }

    @Test("getTrack returns the single requested track")
    func getTrackReadsOneTrack() async throws {
        let (client, _) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"e"}"#) }
            if request.httpMethod == "DELETE" { return .empty() }
            return .json(#"{"track":"beta","releases":[{"versionCodes":["99"],"status":"draft"}]}"#)
        }

        let track = try await client.getTrack(packageName: "com.example.app", track: "beta")

        #expect(track.track == "beta")
        #expect(track.releases?.first?.status == .draft)
    }

    @Test("listReviews parses star ratings and developer replies")
    func listReviewsParsesComments() async throws {
        let (client, sessionID) = makeClient { _ in
            .json(
                """
                {"reviews":[{"reviewId":"r1","authorName":"Sam","comments":[
                  {"userComment":{"text":"Crashes on launch","starRating":1,"device":"Pixel 8",
                   "appVersionCode":412,"appVersionName":"4.2.0"}},
                  {"developerComment":{"text":"Fixed in 4.2.1"}}
                ]}]}
                """)
        }

        let reviews = try await client.listReviews(packageName: "com.example.app", maxResults: 10)

        #expect(reviews.count == 1)
        #expect(reviews[0].authorName == "Sam")
        #expect(reviews[0].comments?.compactMap(\.userComment).first?.starRating == 1)

        // Reviews are not edit-scoped, so no edit should be created for them.
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(!requests.contains { $0.path.hasSuffix("/edits") })
        #expect(requests.first?.query?.contains("maxResults=10") == true)
    }

    @Test("updateRollout rewrites the in-progress release and commits")
    func updateRolloutCommits() async throws {
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"edit-3"}"#) }
            if request.httpMethod == "GET" {
                return .json(#"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.1}]}"#)
            }
            if request.httpMethod == "PUT" {
                return .json(#"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.5}]}"#)
            }
            if path.hasSuffix(":commit") { return .json(#"{"id":"edit-3"}"#) }
            return .error(statusCode: 404)
        }

        let track = try await client.updateRollout(
            packageName: "com.example.app", track: "production", userFraction: 0.5)

        #expect(track.releases?.first?.userFraction == 0.5)
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.contains { $0.path.hasSuffix(":commit") })
        #expect(!requests.contains { $0.method == "DELETE" })
    }

    @Test("updateRollout rejects a fraction outside 0...1 before touching the network")
    func updateRolloutValidatesFraction() async throws {
        let (client, sessionID) = makeClient { _ in .error(statusCode: 500) }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 1.5)
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty)
    }

    @Test("haltRollout drops userFraction, which Play rejects on a halted release")
    func haltRolloutOmitsFraction() async throws {
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"edit-4"}"#) }
            if request.httpMethod == "GET" {
                return .json(#"{"track":"production","releases":[{"versionCodes":["412"],"status":"inProgress","userFraction":0.3}]}"#)
            }
            if request.httpMethod == "PUT" {
                return .json(#"{"track":"production","releases":[{"versionCodes":["412"],"status":"halted"}]}"#)
            }
            return .json(#"{"id":"edit-4"}"#)
        }

        _ = try await client.haltRollout(packageName: "com.example.app", track: "production")

        let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
        let body = try #require(put.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("halted"))
        #expect(!body.contains("userFraction"))
    }

    @Test("updateRollout preserves the other releases on the track")
    func updateRolloutKeepsSiblingReleases() async throws {
        // A track routinely carries a completed release (older device configs) alongside the
        // in-progress staged rollout. PUT replaces the whole array, so both must be sent back.
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"edit-6"}"#) }
            if request.httpMethod == "GET" {
                return .json(
                    """
                    {"track":"production","releases":[
                      {"versionCodes":["400"],"status":"completed"},
                      {"versionCodes":["412"],"status":"inProgress","userFraction":0.1}
                    ]}
                    """)
            }
            if request.httpMethod == "PUT" { return .json(#"{"track":"production"}"#) }
            return .json(#"{"id":"edit-6"}"#)
        }

        _ = try await client.updateRollout(
            packageName: "com.example.app", track: "production", userFraction: 0.5)

        let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
        let body = try #require(put.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("400"), "the completed release must survive the rollout change")
        #expect(body.contains("412"))
        #expect(body.contains("0.5"))
    }

    @Test("haltRollout preserves the other releases on the track")
    func haltRolloutKeepsSiblingReleases() async throws {
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"edit-7"}"#) }
            if request.httpMethod == "GET" {
                return .json(
                    """
                    {"track":"production","releases":[
                      {"versionCodes":["400"],"status":"completed"},
                      {"versionCodes":["412"],"status":"inProgress","userFraction":0.3}
                    ]}
                    """)
            }
            if request.httpMethod == "PUT" { return .json(#"{"track":"production"}"#) }
            return .json(#"{"id":"edit-7"}"#)
        }

        _ = try await client.haltRollout(packageName: "com.example.app", track: "production")

        let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
        let body = try #require(put.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("400"), "the completed release must survive the halt")
        #expect(body.contains("halted"))
    }

    @Test("a translation language is percent-encoded into the reviews query")
    func reviewTranslationLanguageIsEncoded() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"reviews":[]}"#) }

        _ = try await client.listReviews(
            packageName: "com.example.app", maxResults: 5, translationLanguage: "pt BR")

        let query = try #require(MockURLProtocol.requests(for: sessionID).first?.query)
        #expect(query.contains("translationLanguage=pt%20BR"))
    }

    @Test("updateRollout fails when the track has no in-progress release")
    func updateRolloutRequiresInProgressRelease() async throws {
        let (client, sessionID) = makeClient { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/edits") { return .json(#"{"id":"edit-5"}"#) }
            if request.httpMethod == "GET" {
                return .json(#"{"track":"production","releases":[{"versionCodes":["412"],"status":"completed"}]}"#)
            }
            return .empty()
        }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
        }
        // The edit opened for the read must not be left behind.
        #expect(MockURLProtocol.requests(for: sessionID).contains { $0.method == "DELETE" })
    }

    @Test("an API error carries Google's error message, not the raw envelope")
    func apiErrorSurfacesGoogleMessage() async throws {
        let (client, _) = makeClient { _ in
            .error(
                statusCode: 403,
                body: #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#)
        }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.listReviews(packageName: "com.example.app")
        }

        do {
            _ = try await client.listReviews(packageName: "com.example.app")
        } catch let error as GoogleAPIError {
            let description = error.localizedDescription
            #expect(description.contains("The caller does not have permission"))
            #expect(description.contains("PERMISSION_DENIED"))
        }
    }

    @Test("uploadDataSafetyLabels tolerates the empty success body")
    func dataSafetyUploadAcceptsEmptyResponse() async throws {
        let (client, sessionID) = makeClient { _ in .empty(statusCode: 200) }

        try await client.uploadDataSafetyLabels(packageName: "com.example.app", safetyLabelsCSV: "a,b\n1,2")

        let request = try #require(MockURLProtocol.requests(for: sessionID).first)
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/dataSafety"))
    }
}
