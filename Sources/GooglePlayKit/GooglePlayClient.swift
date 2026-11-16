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
    /// How transient failures of idempotent requests are retried.
    let retryPolicy: GooglePlayRetryPolicy
    private let logger = Logger(label: "GooglePlayKit.Client")

    // MARK: - Init

    /// Creates a client from parsed service account credentials.
    public init(
        credentials: GoogleServiceAccountCredentials,
        session: URLSession = .shared,
        retryPolicy: GooglePlayRetryPolicy = .default
    ) {
        let generator = GoogleServiceAccountJWTGenerator(
            credentials: credentials,
            scope: .androidPublisher,
            session: session
        )
        self.session = session
        self.tokenProvider = { try await generator.cachedOrNewToken() }
        self.retryPolicy = retryPolicy
    }

    /// Creates a client from the raw bytes of a service account key JSON file.
    public init(
        serviceAccountJSON: Data,
        session: URLSession = .shared,
        retryPolicy: GooglePlayRetryPolicy = .default
    ) throws {
        self.init(
            credentials: try GoogleServiceAccountCredentials(json: serviceAccountJSON),
            session: session,
            retryPolicy: retryPolicy)
    }

    /// Creates a client by reading a service account key JSON file from disk.
    public init(
        serviceAccountJSONPath: String,
        session: URLSession = .shared,
        retryPolicy: GooglePlayRetryPolicy = .default
    ) throws {
        self.init(
            credentials: try GoogleServiceAccountCredentials(jsonPath: serviceAccountJSONPath),
            session: session,
            retryPolicy: retryPolicy)
    }

    /// Creates a client with an explicit token provider and URL session.
    ///
    /// This is the supported injection seam for tests, and for callers that authenticate some
    /// other way (for example a `WorkloadIdentityFederationClient` created with the
    /// `androidPublisher` scope). A canned token skips RSA signing and the OAuth2 round trip
    /// entirely, so a mocked `URLSession` only has to answer the API calls under test. It is
    /// `public` precisely so downstream packages can test against Play without reaching for
    /// `@testable`.
    public init(
        tokenProvider: @escaping @Sendable () async throws -> String,
        session: URLSession,
        retryPolicy: GooglePlayRetryPolicy = .default
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.retryPolicy = retryPolicy
    }

    // MARK: - HTTP Primitives

    /// Performs a GET request and decodes the response. Retried on a transient failure.
    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try request("GET", path))
    }

    /// Performs a POST request with an encodable body and decodes the response.
    ///
    /// Never retried: a POST such as `edits.insert` or `edits.commit` is not safe to repeat.
    public func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await perform(try request("POST", path, body: body))
    }

    /// Performs a POST request with no body and decodes the response. Never retried.
    public func post<T: Decodable>(_ path: String) async throws -> T {
        try await perform(try request("POST", path))
    }

    /// Performs a PUT request with an encodable body and decodes the response. Retried on a
    /// transient failure, since a PUT replaces the resource and is safe to repeat.
    public func put<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await perform(try request("PUT", path, body: body))
    }

    /// Performs a PATCH request with an encodable body and decodes the response. Never retried.
    public func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await perform(try request("PATCH", path, body: body))
    }

    /// Performs a POST request with an encodable body, discarding the (empty) response body.
    ///
    /// Some Play endpoints — `applications.dataSafety` among them — answer a success with no
    /// content at all, which a decoding call would misreport as a malformed response.
    public func postExpectingNoContent<B: Encodable>(_ path: String, body: B) async throws {
        _ = try await send(try request("POST", path, body: body))
    }

    /// Performs a DELETE request, discarding the (empty) response body.
    ///
    /// `edits.delete` returns 204 with no content, so there is nothing to decode. Retried on a
    /// transient failure; a `404` on a retry counts as success, because it means an earlier
    /// attempt deleted the resource and only its response was lost.
    public func delete(_ path: String) async throws {
        _ = try await send(try request("DELETE", path), notFoundOnRetryIsSuccess: true)
    }

    /// Uploads in-memory binary data to the Play media-upload endpoint.
    ///
    /// Prefer ``uploadFile(path:fileURL:contentType:)`` for artifacts on disk: this holds the whole
    /// payload in memory.
    public func uploadBinary(path: String, data: Data, contentType: String) async throws -> Data {
        var request = try await uploadRequest(path: path, contentType: contentType)
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data

        logger.info("Uploading \(data.count) bytes to \(path)")
        let (responseData, response) = try await responseData(for: request)
        return try Self.validateUpload(response: response, data: responseData, path: path)
    }

    /// Streams a file on disk to the Play media-upload endpoint.
    ///
    /// URLSession reads the file as it sends, so a multi-hundred-megabyte AAB never has to fit in
    /// memory — which matters most inside a long-running MCP server.
    public func uploadFile(path: String, fileURL: URL, contentType: String) async throws -> Data {
        let request = try await uploadRequest(path: path, contentType: contentType)

        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue
        logger.info("Uploading \(size.map { "\($0) bytes" } ?? "file") from \(fileURL.lastPathComponent) to \(path)")
        let (responseData, response) = try await uploadData(for: request, fileURL: fileURL)
        return try Self.validateUpload(response: response, data: responseData, path: path)
    }

    // MARK: - Private

    /// An authorized `POST` to the media-upload endpoint, with no body attached yet.
    private func uploadRequest(path: String, contentType: String) async throws -> URLRequest {
        guard let url = URL(string: "\(Self.uploadBaseURL)\(path)?uploadType=media") else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: invalid upload URL for path '\(path)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600  // 10 minutes — AAB uploads can be large
        return request
    }

    private static func validateUpload(response: URLResponse, data: Data, path: String) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GoogleAPIError.uploadFailed(
                asset: path,
                reason: "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")"
            )
        }
        return data
    }

    private func bearerToken() async throws -> String {
        do { return try await tokenProvider() } catch let error as GoogleAPIError { throw error } catch {
            throw GoogleAPIError.apiError(statusCode: 0, body: "Token provider failed: \(error.localizedDescription)")
        }
    }

    private func encode<B: Encodable>(_ body: B) throws -> Data {
        do { return try JSONEncoder().encode(body) } catch {
            throw GoogleAPIError.invalidConfiguration(reason: "Could not encode request: \(error.localizedDescription)")
        }
    }

    private func responseData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch {
            throw GoogleAPIError.apiError(
                statusCode: 0, body: "Request to \(request.url?.path ?? "") failed: \(error.localizedDescription)")
        }
    }

    private func uploadData(for request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        do { return try await session.upload(for: request, fromFile: fileURL) } catch {
            throw GoogleAPIError.uploadFailed(asset: fileURL.lastPathComponent, reason: error.localizedDescription)
        }
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: invalid URL for path '\(path)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func request<B: Encodable>(_ method: String, _ path: String, body: B) throws -> URLRequest {
        var request = try request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encode(body)
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleAPIError.decodingFailed(path: request.url?.path ?? "", type: "\(T.self)", underlying: error)
        }
    }

    /// Authorizes and sends a request, returning the body of a 2xx response.
    ///
    /// Idempotent methods (`GET`, `PUT`, `DELETE`) are retried under ``retryPolicy`` when Play
    /// answers with a transient status or the connection fails. Everything else is sent once.
    private func send(_ request: URLRequest, notFoundOnRetryIsSuccess: Bool = false) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let attempts = GooglePlayRetryPolicy.idempotentMethods.contains(method) ? max(1, retryPolicy.maxAttempts) : 1

        var attempt = 1
        while true {
            var authorized = request
            authorized.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")

            let outcome: Result<(Data, URLResponse), GoogleAPIError>
            do {
                outcome = .success(try await responseData(for: authorized))
            } catch {
                outcome = .failure(Self.asAPIError(error))
            }

            var retryAfter: String?
            let failure: GoogleAPIError
            switch outcome {
            case .success(let (data, response)):
                let http = response as? HTTPURLResponse
                if let http, attempt > 1, notFoundOnRetryIsSuccess, http.statusCode == 404 {
                    logger.info("\(method) \(path) returned 404 on retry; an earlier attempt already succeeded")
                    return data
                }
                do {
                    try Self.validate(response: response, data: data, path: path)
                    return data
                } catch {
                    failure = Self.asAPIError(error)
                    retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
                }
            case .failure(let error):
                failure = error
            }

            guard attempt < attempts, GooglePlayRetryPolicy.isTransient(failure), !Task.isCancelled else {
                throw failure
            }
            let delay = retryPolicy.delay(afterAttempt: attempt, retryAfter: retryAfter)
            logger.info("\(method) \(path) failed transiently (attempt \(attempt) of \(attempts)); retrying in \(delay)")
            try? await Task.sleep(for: delay)
            if Task.isCancelled { throw failure }
            attempt += 1
        }
    }

    private static func asAPIError(_ error: any Error) -> GoogleAPIError {
        error as? GoogleAPIError ?? .apiError(statusCode: 0, body: error.localizedDescription)
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
    /// requests (for an endpoint this package does not wrap yet) do not have to re-derive the
    /// token flow.
    public func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        return request
    }
}
