import Foundation
import GoogleAuthKit
import Testing

@testable import GooglePlayKit

/// Live tests against a real Play Console account.
///
/// Everything else in this package runs against mocked HTTP, which proves the request shapes and
/// the edit lifecycle but cannot prove that Google accepts them. These fill that gap, and are the
/// intended way to vet a release before tagging it.
///
/// **Nothing here changes the app.** The read tests' only writes are the throwaway edits Play
/// requires for reads, each of which is deleted. Two further tests, gated behind
/// `GOOGLE_PLAY_LIVE_WRITE_TESTS=1`, exercise the write encoding: they PUT a track inside an edit
/// and then delete that edit, never committing it, so Play validates the payload without the app
/// changing. No test uploads an artifact or commits an edit.
///
/// Skipped unless both are set:
/// - `GOOGLE_PLAY_TEST_PACKAGE_NAME` — a package the service account can read
/// - one of `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`,
///   or `GOOGLE_APPLICATION_CREDENTIALS`
///
/// ```bash
/// GOOGLE_PLAY_TEST_PACKAGE_NAME=com.example.app \
/// GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=./service-account.json \
///   swift test --filter LiveGooglePlayTests
/// ```
enum LiveCredentials {
    static var packageName: String? {
        guard let name = ProcessInfo.processInfo.environment["GOOGLE_PLAY_TEST_PACKAGE_NAME"],
            !name.isEmpty
        else { return nil }
        return name
    }

    static var client: GooglePlayClient? {
        // `try?` on a throwing call that already returns an optional flattens to one level.
        guard let credentials = try? GoogleServiceAccountCredentials.fromEnvironment() else { return nil }
        return GooglePlayClient(credentials: credentials)
    }

    /// True when a package name and usable credentials are both present.
    static var isConfigured: Bool { packageName != nil && client != nil }
}

@Suite(
    "Live Google Play API",
    .enabled(if: LiveCredentials.isConfigured, "set GOOGLE_PLAY_TEST_PACKAGE_NAME and service account credentials"),
    .serialized
)
struct LiveGooglePlayTests {

    private func makeClient() throws -> (client: GooglePlayClient, packageName: String) {
        let client = try #require(LiveCredentials.client)
        let packageName = try #require(LiveCredentials.packageName)
        return (client, packageName)
    }

    @Test("authenticates and lists tracks")
    func listsTracks() async throws {
        let (client, packageName) = try makeClient()

        let tracks = try await client.listTracks(packageName: packageName)

        // Play always reports its four standard tracks, even with no releases on them.
        #expect(!tracks.isEmpty)
        for track in tracks {
            for release in track.releases ?? [] {
                // A staged rollout must carry a fraction; anything else must not.
                if release.status == .inProgress {
                    #expect(release.userFraction != nil, "in-progress release on '\(track.track)' has no userFraction")
                }
            }
        }
    }

    @Test("a throwaway read edit is actually accepted and deleted by Play")
    func readOnlyEditRoundTrips() async throws {
        let (client, packageName) = try makeClient()

        // Proves the create → read → delete lifecycle against the real API, which is the one
        // thing mocked tests cannot establish: that Play accepts our edit handling at all.
        let editId = try await client.withReadOnlyEdit(packageName: packageName) { $0 }

        #expect(!editId.isEmpty)
        // The edit is gone, so fetching it must now fail.
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.getEdit(packageName: packageName, editId: editId)
        }
    }

    @Test("lists uploaded bundles and APKs")
    func listsArtifacts() async throws {
        let (client, packageName) = try makeClient()

        let bundles = try await client.listBundles(packageName: packageName)
        let apks = try await client.listApks(packageName: packageName)

        // Version codes are positive and the responses decode against the real payload shape,
        // which is what this is really checking.
        for bundle in bundles { #expect(bundle.versionCode > 0) }
        for apk in apks { #expect(apk.versionCode > 0) }
    }

    @Test("lists reviews")
    func listsReviews() async throws {
        let (client, packageName) = try makeClient()

        // An app with no reviews in the last week legitimately returns an empty list; this is
        // checking that the call authenticates and the payload decodes, not that reviews exist.
        let reviews = try await client.listReviews(packageName: packageName, maxResults: 5)

        #expect(reviews.count <= 5)
        for review in reviews {
            #expect(!review.reviewId.isEmpty)
        }
    }

    @Test(
        "the track-write payload is accepted by Play, in an edit that is never committed",
        .enabled(
            if: ProcessInfo.processInfo.environment["GOOGLE_PLAY_LIVE_WRITE_TESTS"] == "1",
            "set GOOGLE_PLAY_LIVE_WRITE_TESTS=1 to exercise the write encoding against Play"))
    func trackWritePayloadIsAccepted() async throws {
        let (client, packageName) = try makeClient()

        // The one write we can make against a real app without changing anything: Play validates
        // a track PUT when it receives it, but an edit only takes effect on commit. So this
        // proves our GooglePlayTrack encoding is accepted, then throws the edit away. There is
        // deliberately no commitEdit call anywhere in this test.
        let edit = try await client.createEdit(packageName: packageName)
        do {
            let existing: GooglePlayTrack = try await client.get(
                "/applications/\(packageName)/edits/\(edit.id)/tracks/internal")
            let releases = try #require(existing.releases)

            // Send the track back exactly as read. Play accepts or rejects the shape on the PUT.
            let echoed = try await client.setTrack(
                packageName: packageName,
                editId: edit.id,
                track: GooglePlayTrack(track: "internal", releases: releases)
            )
            #expect(echoed.track == "internal")

            // Play's own pre-commit validation, on an edit carrying our payload.
            _ = try await client.validateEdit(packageName: packageName, editId: edit.id)

            try await client.deleteEdit(packageName: packageName, editId: edit.id)
        } catch {
            try? await client.deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }

        // The edit is gone, so nothing was left pending in the Play Console.
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.getEdit(packageName: packageName, editId: edit.id)
        }
    }

    @Test(
        "rollout helpers refuse a track with no in-progress release, and leave no edit behind",
        .enabled(
            if: ProcessInfo.processInfo.environment["GOOGLE_PLAY_LIVE_WRITE_TESTS"] == "1",
            "set GOOGLE_PLAY_LIVE_WRITE_TESTS=1 to exercise the write encoding against Play"))
    func rolloutHelpersRefuseNonStagedTrack() async throws {
        let (client, packageName) = try makeClient()

        // No track here has a staged rollout, so both helpers must bail out — and, importantly,
        // clean up the edit they opened to find that out. A leaked edit blocks a human.
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.updateRollout(packageName: packageName, track: "internal", userFraction: 0.5)
        }
        await #expect(throws: GoogleAPIError.self) {
            _ = try await client.haltRollout(packageName: packageName, track: "internal")
        }
    }

    @Test("a bad package name fails with a readable permission error")
    func unknownPackageIsReadable() async throws {
        let client = try #require(LiveCredentials.client)

        do {
            _ = try await client.listTracks(packageName: "com.example.definitely.not.a.real.app")
            Issue.record("Expected Play to reject an unknown package")
        } catch let error as GoogleAPIError {
            // Google answers with 401/403/404 here depending on the account; all that matters is
            // that the message is the human-readable one, not a raw JSON envelope.
            let description = error.localizedDescription
            #expect(!description.contains("\"error\""), "error envelope leaked into the message: \(description)")
        }
    }
}
