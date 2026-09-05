import Crypto
import CryptoExtras
import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Generates and caches Google OAuth2 access tokens for service account authentication.
///
/// Signs an RS256 JWT with the service account's private key and exchanges it at
/// `https://oauth2.googleapis.com/token` for a scope-limited bearer token.
///
/// ## Usage
/// ```swift
/// let credentials = try GoogleServiceAccountCredentials(jsonPath: "./service-account.json")
/// let generator = GoogleServiceAccountJWTGenerator(credentials: credentials)
/// let token = try await generator.cachedOrNewToken()
///
/// // Firebase App Distribution needs a different scope:
/// let firebase = GoogleServiceAccountJWTGenerator(credentials: credentials, scope: .cloudPlatform)
/// ```
public actor GoogleServiceAccountJWTGenerator: Sendable {

    /// An OAuth2 scope requested when exchanging the signed JWT for an access token.
    ///
    /// Google issues scope-limited tokens, so each API family needs the scope it accepts:
    /// the Play Developer API only honours ``androidPublisher``, while the Firebase App
    /// Distribution API only honours ``cloudPlatform``.
    public struct Scope: RawRepresentable, Hashable, Sendable {
        /// The fully-qualified scope URL sent in the JWT payload.
        public let rawValue: String

        /// Creates a scope from a fully-qualified Google OAuth2 scope URL.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Scope for the Google Play Developer API (`androidpublisher`).
        public static let androidPublisher = Scope(rawValue: "https://www.googleapis.com/auth/androidpublisher")

        /// Scope for the Firebase App Distribution API (`cloud-platform`).
        public static let cloudPlatform = Scope(rawValue: "https://www.googleapis.com/auth/cloud-platform")
    }

    private let credentials: GoogleServiceAccountCredentials
    private let scope: Scope
    /// The raw request/response transport, matching `URLSession.data(for:)`'s signature so
    /// production wraps a session while tests inject a closure — no `URLProtocol` registration,
    /// whose session-scoped routing is unreliable across concurrently running suites on Linux.
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let logger = Logger(label: "GoogleAuthKit.JWTGenerator")

    private var cachedToken: String?
    private var tokenExpiresAt: Date?

    /// Creates a generator with service account credentials.
    ///
    /// - Parameters:
    ///   - credentials: The parsed service-account key.
    ///   - scope: The OAuth2 scope to request. Defaults to ``Scope/androidPublisher``.
    ///   - session: Overridable for tests; defaults to `.shared`.
    public init(
        credentials: GoogleServiceAccountCredentials,
        scope: Scope = .androidPublisher,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.scope = scope
        self.transport = { request in try await session.data(for: request) }
    }

    /// Creates a generator with an injected transport, bypassing `URLSession` entirely.
    ///
    /// Intended for tests: a plain closure is a fully deterministic test double.
    public init(
        credentials: GoogleServiceAccountCredentials,
        scope: Scope = .androidPublisher,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.credentials = credentials
        self.scope = scope
        self.transport = transport
    }

    /// Returns a valid access token, reusing the cached token if it has more than 60s left.
    public func cachedOrNewToken() async throws -> String {
        let now = Date()
        if let token = cachedToken, let expiry = tokenExpiresAt, expiry.timeIntervalSince(now) > 60 {
            return token
        }
        return try await fetchNewToken()
    }

    // MARK: - Internal (exercised directly by tests)

    /// Builds the signed RS256 assertion sent to Google's token endpoint.
    func buildJWT() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let expiry = now + 3600

        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let headerB64 = base64URLEncode(Data(header.utf8))

        let payload = """
            {
              "iss": "\(credentials.clientEmail)",
              "scope": "\(scope.rawValue)",
              "aud": "\(credentials.tokenUri)",
              "iat": \(now),
              "exp": \(expiry)
            }
            """
        let payloadB64 = base64URLEncode(Data(payload.utf8))

        let signingInput = "\(headerB64).\(payloadB64)"
        let signature = try rsaSign(input: signingInput, pemKey: credentials.privateKey)
        return "\(signingInput).\(base64URLEncode(signature))"
    }

    // MARK: - Private

    private func fetchNewToken() async throws -> String {
        logger.info("Fetching new Google OAuth2 access token for \(credentials.clientEmail)")

        let jwt = try buildJWT()
        let tokenResponse = try await exchangeJWTForToken(jwt: jwt)

        cachedToken = tokenResponse.accessToken
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        logger.info("Google OAuth2 token fetched, expires in \(tokenResponse.expiresIn)s")
        return tokenResponse.accessToken
    }

    /// RS256 signing for Google service-account PKCS#8 PEM keys.
    private func rsaSign(input: String, pemKey: String) throws -> Data {
        do {
            let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: pemKey)
            let digest = SHA256.hash(data: Data(input.utf8))
            let signature = try privateKey.signature(for: digest, padding: .insecurePKCS1v1_5)
            return signature.rawRepresentation
        } catch {
            throw GoogleAPIError.jwtGenerationFailed(underlying: error)
        }
    }

    private func exchangeJWTForToken(jwt: String) async throws -> GoogleOAuth2TokenResponse {
        guard let url = URL(string: credentials.tokenUri) else {
            throw GoogleAPIError.invalidConfiguration(reason: "Invalid OAuth2 token URI '\(credentials.tokenUri)'")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await transport(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GoogleAPIError.apiError(statusCode: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try JSONDecoder().decode(GoogleOAuth2TokenResponse.self, from: data)
        } catch {
            throw GoogleAPIError.decodingFailed(
                path: "oauth2/token",
                type: "GoogleOAuth2TokenResponse",
                underlying: error
            )
        }
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
