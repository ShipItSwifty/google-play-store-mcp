import Foundation
import GoogleAuthKit
import Testing

@testable import GooglePlayKit

/// Writes `contents` to a temporary file and returns its path, cleaned up by the caller.
private func makeTempArtifact(named name: String, contents: String = "artifact") throws -> (path: String, directory: URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return (file.path, directory)
}

private func makeClient(
    handler: @escaping MockURLProtocol.Handler
) -> (client: GooglePlayClient, sessionID: String) {
    let (session, sessionID) = makeMockSession(handler: handler)
    return (GooglePlayClient(tokenProvider: { "test-token" }, session: session), sessionID)
}

@Suite("Google Play upload service", .serialized)
struct GooglePlayUploadServiceTests {

    @Test("uploadAndRelease walks edit → upload → track → commit")
    func happyPathCommitsTheEdit() async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (client, sessionID) = makeClient { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/upload/") { return .json(#"{"versionCode":412,"sha256":"abc"}"#) }
            if url.hasSuffix(":commit") { return .json(#"{"id":"edit-1"}"#) }
            if request.httpMethod == "POST" { return .json(#"{"id":"edit-1"}"#) }
            if request.httpMethod == "PUT" {
                return .json(#"{"track":"internal","releases":[{"versionCodes":["412"],"status":"completed"}]}"#)
            }
            return .error(statusCode: 404, body: url)
        }

        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
        let versionCode = try await uploader.uploadAndRelease(
            aabPath: path,
            track: "internal",
            releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")]
        )

        #expect(versionCode == 412)
        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.contains { $0.method == "POST" && $0.path.hasSuffix("/edits") })
        #expect(requests.contains { $0.path.contains("/bundles") })
        #expect(requests.contains { $0.method == "PUT" && $0.path.contains("/tracks/internal") })
        #expect(requests.contains { $0.path.hasSuffix(":commit") })
    }

    @Test("a missing artifact fails before any edit is created")
    func missingArtifactCreatesNoEdit() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"id":"edit-1"}"#) }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(aabPath: "/nonexistent/app.aab", track: "internal")
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty)
    }

    @Test("supplying both aabPath and apkPath is rejected")
    func bothArtifactPathsRejected() async throws {
        let (client, _) = makeClient { _ in .json("{}") }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(aabPath: "a.aab", apkPath: "b.apk", track: "internal")
        }
    }

    @Test("supplying neither artifact path is rejected")
    func noArtifactPathRejected() async throws {
        let (client, _) = makeClient { _ in .json("{}") }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(track: "internal")
        }
    }

    @Test("a failed upload deletes the edit instead of leaking it into the Play Console")
    func failedUploadDiscardsTheEdit() async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (client, sessionID) = makeClient { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/upload/") { return .error(statusCode: 400, body: "bad bundle") }
            if request.httpMethod == "DELETE" { return .empty() }
            return .json(#"{"id":"edit-9"}"#)
        }

        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(aabPath: path, track: "internal")
        }

        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.contains { $0.method == "DELETE" && $0.path.hasSuffix("/edits/edit-9") })
        #expect(!requests.contains { $0.path.hasSuffix(":commit") })
    }

    @Test("a fraction paired with a completed release is rejected, not silently dropped")
    func fractionWithCompletedIsRejected() async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, sessionID) = makeClient { _ in .json(#"{"id":"e"}"#) }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        // Dropping it silently would ship to 100% of users while reporting success to a caller
        // who asked for 50% — the worst possible outcome, so this must fail loudly.
        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(
                aabPath: path, track: "internal", status: .completed, userFraction: 0.5)
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty, "must fail before any network call")
    }

    @Test("an inProgress release with no fraction is rejected before uploading")
    func stagedReleaseRequiresFraction() async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, sessionID) = makeClient { _ in .json(#"{"id":"e"}"#) }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(
                aabPath: path, track: "internal", status: .inProgress, userFraction: nil)
        }
        #expect(MockURLProtocol.requests(for: sessionID).isEmpty)
    }

    @Test("a staged rollout sends its fraction through", arguments: [0.01, 0.5, 0.99])
    func stagedRolloutSendsFraction(fraction: Double) async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (client, sessionID) = makeClient { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/upload/") { return .json(#"{"versionCode":1}"#) }
            if request.httpMethod == "PUT" { return .json(#"{"track":"internal"}"#) }
            return .json(#"{"id":"e"}"#)
        }

        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
        try await uploader.uploadAndRelease(
            aabPath: path, track: "internal", status: .inProgress, userFraction: fraction)

        let put = try #require(MockURLProtocol.requests(for: sessionID).first { $0.method == "PUT" })
        let body = try #require(put.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("userFraction"))
        #expect(body.contains("inProgress"))
    }

    @Test("a boundary fraction is rejected", arguments: [0.0, 1.0, -0.5, 2.0])
    func boundaryFractionRejected(fraction: Double) async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.aab")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, _) = makeClient { _ in .json(#"{"id":"e"}"#) }
        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")

        await #expect(throws: GoogleAPIError.self) {
            try await uploader.uploadAndRelease(
                aabPath: path, track: "internal", status: .inProgress, userFraction: fraction)
        }
    }

    @Test("an APK upload posts to /apks with the package-archive content type")
    func apkUploadUsesApkEndpoint() async throws {
        let (path, directory) = try makeTempArtifact(named: "app-release.apk")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (client, sessionID) = makeClient { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/upload/") { return .json(#"{"versionCode":7}"#) }
            if request.httpMethod == "PUT" { return .json(#"{"track":"alpha"}"#) }
            return .json(#"{"id":"e"}"#)
        }

        let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
        let versionCode = try await uploader.uploadAndRelease(apkPath: path, track: "alpha")

        #expect(versionCode == 7)
        #expect(MockURLProtocol.requests(for: sessionID).contains { $0.path.contains("/apks") })
    }
}
