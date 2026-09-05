import Foundation
import GoogleAuthKit
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// JWT-authenticated HTTP client for the Google Play Developer API (v3).
///
/// ## Authentication
/// Authenticates using a Google Cloud service account JSON key via the OAuth2 service
/// account JWT flow (RS256), scoped to `androidpublisher`.
///
/// ## Usage
/// ```swift
/// let client = try GooglePlayClient(serviceAccountJSONPath: "/path/to/key.json")
///
/// // Reads (see `GooglePlayReadAPI`)
/// let tracks = try await client.listTracks(packageName: "com.example.app")
///
/// // Writes
/// let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
/// try await uploader.uploadAndRelease(aabPath: "./build/app-release.aab", track: "qa")
/// ```
public struct GooglePlayClient: Sendable {

    /// Base URL for the Google Play Developer API.
    public static let baseURL = "https://androidpublisher.googleapis.com/androidpublisher/v3"

    /// Base URL for media uploads.
    public static let uploadBaseURL = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"

    let session: URLSession
    /// Resolves the bearer token for each request. Backed by the JWT generator in production,
    /// or by a canned closure in tests.
    let tokenProvider: @Sendable () async throws -> String
    private let logger = Logger(label: "GooglePlayKit.Client")

    // MARK: - Init

    /// Creates a client from parsed service account credentials.
    public init(credentials: GoogleServiceAccountCredentials, session: URLSession = .shared) {
        let generator = GoogleServiceAccountJWTGenerator(
            credentials: credentials,
            scope: .androidPublisher,
            session: session
        )
        self.session = session
        self.tokenProvider = { try await generator.cachedOrNewToken() }
    }

    /// Creates a client from the raw bytes of a service account key JSON file.
    public init(serviceAccountJSON: Data, session: URLSession = .shared) throws {
        self.init(credentials: try GoogleServiceAccountCredentials(json: serviceAccountJSON), session: session)
    }

    /// Creates a client by reading a service account key JSON file from disk.
    public init(serviceAccountJSONPath: String, session: URLSession = .shared) throws {
        self.init(credentials: try GoogleServiceAccountCredentials(jsonPath: serviceAccountJSONPath), session: session)
    }

    /// Creates a client with an explicit token provider and URL session.
    ///
    /// This is the supported injection seam for tests: a canned token skips RSA signing and the
    /// OAuth2 round trip entirely, so a mocked `URLSession` only has to answer the API calls
    /// under test. It is `public` precisely so downstream packages can test against Play without
    /// reaching for `@testable`.
    public init(tokenProvider: @escaping @Sendable () async throws -> String, session: URLSession) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - HTTP Primitives

    /// Performs a GET request and decodes the response.
    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try request("GET", path))
    }

    /// Performs a POST request with an encodable body and decodes the response.
    public func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = try request("POST", path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// Performs a POST request with no body and decodes the response.
    public func post<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try request("POST", path))
    }

    /// Performs a PUT request with an encodable body and decodes the response.
    public func put<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = try request("PUT", path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// Performs a PATCH request with an encodable body and decodes the response.
    public func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = try request("PATCH", path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// Performs a POST request with an encodable body, discarding the (empty) response body.
    ///
    /// Some Play endpoints — `applications.dataSafety` among them — answer a success with no
    /// content at all, which a decoding call would misreport as a malformed response.
    public func postExpectingNoContent<B: Encodable>(_ path: String, body: B) async throws {
        var request = try request("POST", path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, path: path)
    }

    /// Performs a DELETE request, discarding the (empty) response body.
    ///
    /// `edits.delete` returns 204 with no content, so there is nothing to decode.
    public func delete(_ path: String) async throws {
        var request = try request("DELETE", path)
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, path: path)
    }

    /// Uploads binary data to the Play media-upload endpoint.
    public func uploadBinary(path: String, data: Data, contentType: String) async throws -> Data {
        let token = try await tokenProvider()
        guard let url = URL(string: "\(Self.uploadBaseURL)\(path)?uploadType=media") else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: invalid upload URL for path '\(path)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        request.timeoutInterval = 600  // 10 minutes — AAB uploads can be large

        logger.info("Uploading \(data.count) bytes to \(path)")
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GoogleAPIError.uploadFailed(
                asset: path,
                reason: "HTTP \(status): \(String(data: responseData, encoding: .utf8) ?? "")"
            )
        }
        return responseData
    }

    // MARK: - Private

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: invalid URL for path '\(path)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")

        let path = request.url?.path ?? ""
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data, path: path)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleAPIError.decodingFailed(path: path, type: "\(T.self)", underlying: error)
        }
    }

    private static func validate(response: URLResponse, data: Data, path: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAPIError.apiError(statusCode: 0, body: "No HTTP response received for '\(path)'")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GoogleAPIError.apiError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? "(empty)"
            )
        }
    }
}

extension GooglePlayClient {
    /// Sets the `Authorization` header on a request, exposed so callers assembling their own
    /// requests (the MCP server's raw passthrough) do not have to re-derive the token flow.
    public func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        return request
    }
}
