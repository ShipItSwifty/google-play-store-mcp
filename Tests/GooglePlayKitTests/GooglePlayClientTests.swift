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

private struct Echo: Codable, Sendable, Equatable {
    let value: String
}

/// Exercises the HTTP primitives on `GooglePlayClient` directly — most are only reached
/// indirectly through `GooglePlayReadAPI`/`GooglePlayUploadService`, which don't touch every
/// verb (`patch`) or helper (`authorized(_:)`) that downstream consumers rely on directly.
@Suite("Google Play client HTTP primitives", .serialized)
struct GooglePlayClientTests {

    @Test("GET decodes a 2xx JSON body")
    func getDecodes() async throws {
        let (client, _) = makeClient { _ in .json(#"{"value":"hi"}"#) }
        let result: Echo = try await client.get("/anything")
        #expect(result == Echo(value: "hi"))
    }

    @Test("POST with a body sends JSON and decodes the response")
    func postWithBodySendsJSON() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"value":"posted"}"#) }
        let result: Echo = try await client.post("/anything", body: Echo(value: "req"))
        #expect(result == Echo(value: "posted"))

        let requests = MockURLProtocol.requests(for: sessionID)
        #expect(requests.first?.method == "POST")
    }

    @Test("PUT sends JSON and decodes the response")
    func putSendsJSON() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"value":"put"}"#) }
        let result: Echo = try await client.put("/anything", body: Echo(value: "req"))
        #expect(result == Echo(value: "put"))
        #expect(MockURLProtocol.requests(for: sessionID).first?.method == "PUT")
    }

    @Test("PATCH sends JSON and decodes the response")
    func patchSendsJSON() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"value":"patched"}"#) }
        let result: Echo = try await client.patch("/anything", body: Echo(value: "req"))
        #expect(result == Echo(value: "patched"))
        #expect(MockURLProtocol.requests(for: sessionID).first?.method == "PATCH")
    }

    @Test("postExpectingNoContent succeeds without a body to decode")
    func postExpectingNoContentSucceeds() async throws {
        let (client, sessionID) = makeClient { _ in .empty(statusCode: 200) }
        try await client.postExpectingNoContent("/anything", body: Echo(value: "req"))
        #expect(MockURLProtocol.requests(for: sessionID).first?.method == "POST")
    }

    @Test("postExpectingNoContent surfaces a non-2xx status")
    func postExpectingNoContentFails() async throws {
        let (client, _) = makeClient { _ in .error(statusCode: 400, body: "bad request") }
        await #expect(throws: GoogleAPIError.self) {
            try await client.postExpectingNoContent("/anything", body: Echo(value: "req"))
        }
    }

    @Test("DELETE succeeds with no content")
    func deleteSucceeds() async throws {
        let (client, sessionID) = makeClient { _ in .empty() }
        try await client.delete("/anything")
        #expect(MockURLProtocol.requests(for: sessionID).first?.method == "DELETE")
    }

    @Test("uploadBinary sends the payload and returns the raw response body")
    func uploadBinarySucceeds() async throws {
        let (client, sessionID) = makeClient { _ in .json(#"{"value":"uploaded"}"#) }
        let data = try await client.uploadBinary(
            path: "/anything", data: Data("payload".utf8), contentType: "application/octet-stream")

        #expect(String(data: data, encoding: .utf8) == #"{"value":"uploaded"}"#)
        let request = try #require(MockURLProtocol.requests(for: sessionID).first)
        #expect(request.method == "POST")
        #expect(request.body == Data("payload".utf8))
    }

    @Test("uploadBinary surfaces a non-2xx status as uploadFailed")
    func uploadBinaryFails() async throws {
        let (client, _) = makeClient { _ in .error(statusCode: 500, body: "server error") }
        do {
            _ = try await client.uploadBinary(path: "/anything", data: Data(), contentType: "application/octet-stream")
            Issue.record("Expected uploadBinary to throw")
        } catch let error as GoogleAPIError {
            guard case .uploadFailed(let asset, let reason) = error else {
                Issue.record("Expected .uploadFailed, got \(error)")
                return
            }
            #expect(asset == "/anything")
            #expect(reason.contains("500"))
        }
    }

    @Test("uploadFile streams a file to the media-upload endpoint and returns the response body")
    func uploadFileSucceeds() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).aab")
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (client, sessionID) = makeClient { _ in .json(#"{"value":"uploaded"}"#) }

        let data = try await client.uploadFile(path: "/anything", fileURL: file, contentType: "application/octet-stream")

        #expect(String(data: data, encoding: .utf8) == #"{"value":"uploaded"}"#)
        let request = try #require(MockURLProtocol.requests(for: sessionID).first)
        #expect(request.method == "POST")
        #expect(request.path.hasPrefix("/upload/androidpublisher/v3"))
        #expect(request.query?.contains("uploadType=media") == true)
        // Whether a URLProtocol can see a file-backed body differs between Darwin and Linux
        // Foundation, so the bytes are only compared when they are visible.
        if let body = request.body, !body.isEmpty {
            #expect(body == Data("payload".utf8))
        }
    }

    @Test("uploadFile surfaces a non-2xx status as uploadFailed")
    func uploadFileFails() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).aab")
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (client, _) = makeClient { _ in .error(statusCode: 413, body: "too large") }

        do {
            _ = try await client.uploadFile(path: "/anything", fileURL: file, contentType: "application/octet-stream")
            Issue.record("Expected uploadFile to throw")
        } catch let error as GoogleAPIError {
            guard case .uploadFailed(_, let reason) = error else {
                Issue.record("Expected .uploadFailed, got \(error)")
                return
            }
            #expect(reason.contains("413"))
        }
    }

    @Test("a non-2xx status is reported with the response body")
    func nonSuccessStatusThrowsAPIError() async throws {
        let (client, _) = makeClient { _ in .error(statusCode: 403, body: #"{"error":{"message":"nope"}}"#) }
        do {
            let _: Echo = try await client.get("/anything")
            Issue.record("Expected a thrown error")
        } catch let error as GoogleAPIError {
            guard case .apiError(let statusCode, let body) = error else {
                Issue.record("Expected .apiError, got \(error)")
                return
            }
            #expect(statusCode == 403)
            #expect(body.contains("nope"))
        }
    }

    @Test("a malformed response body is reported as a decoding failure, not a crash")
    func malformedBodyThrowsDecodingFailed() async throws {
        let (client, _) = makeClient { _ in .json("not json") }
        do {
            let _: Echo = try await client.get("/anything")
            Issue.record("Expected a thrown error")
        } catch let error as GoogleAPIError {
            guard case .decodingFailed(let path, let type, _) = error else {
                Issue.record("Expected .decodingFailed, got \(error)")
                return
            }
            #expect(path.hasSuffix("/anything"))
            #expect(type.contains("Echo"))
        }
    }

    @Test("authorized(_:) sets the bearer token on an arbitrary request")
    func authorizedSetsBearerToken() async throws {
        let (session, _) = makeMockSession(handler: { _ in .empty() })
        let client = GooglePlayClient(tokenProvider: { "test-token" }, session: session)

        let request = URLRequest(url: URL(string: "https://example.com")!)
        let authorized = try await client.authorized(request)

        #expect(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }
}
