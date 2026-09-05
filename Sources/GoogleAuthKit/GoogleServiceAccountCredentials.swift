import Foundation

/// Service account credentials loaded from a Google Cloud service account JSON key file.
public struct GoogleServiceAccountCredentials: Sendable {
    /// Service account email.
    public let clientEmail: String
    /// PEM-encoded RSA private key.
    public let privateKey: String
    /// Token URI (typically `https://oauth2.googleapis.com/token`).
    public let tokenUri: String
    /// Project ID.
    public let projectId: String?

    enum CodingKeys: String, CodingKey {
        case clientEmail = "client_email"
        case privateKey = "private_key"
        case tokenUri = "token_uri"
        case projectId = "project_id"
    }

    /// Creates credentials directly, bypassing JSON decoding.
    public init(clientEmail: String, privateKey: String, tokenUri: String, projectId: String? = nil) {
        self.clientEmail = clientEmail
        self.privateKey = privateKey
        self.tokenUri = tokenUri
        self.projectId = projectId
    }

    /// Decodes credentials from the raw bytes of a service account key JSON file.
    ///
    /// - Throws: ``GoogleAPIError/invalidConfiguration(reason:)`` when the JSON is not a
    ///   service-account key — a far more useful message than a bare `DecodingError` when a
    ///   user points the tool at the wrong file (an OAuth client secret is a common mix-up).
    public init(json: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: json)
        } catch {
            throw GoogleAPIError.invalidConfiguration(
                reason: """
                    Could not read a Google service account key from the supplied JSON. Expected \
                    `client_email`, `private_key`, and `token_uri` fields — \(error.localizedDescription)
                    """
            )
        }
    }

    /// Reads and decodes credentials from a service account key JSON file on disk.
    public init(jsonPath: String) throws {
        let url = URL(fileURLWithPath: jsonPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GoogleAPIError.invalidConfiguration(
                reason: "Google service account JSON not found at '\(jsonPath)'"
            )
        }
        try self.init(json: try Data(contentsOf: url))
    }

    /// Resolves credentials from the conventional environment variables, in priority order:
    /// `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (raw JSON), `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`,
    /// then `GOOGLE_APPLICATION_CREDENTIALS` (the Google-wide convention).
    ///
    /// - Returns: `nil` when none of the variables is set. Throws only when a variable *is*
    ///   set but its contents cannot be read — a misconfigured key should not look identical
    ///   to no key at all.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GoogleServiceAccountCredentials? {
        if let raw = environment["GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"], !raw.isEmpty {
            return try GoogleServiceAccountCredentials(json: Data(raw.utf8))
        }
        if let path = environment["GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH"], !path.isEmpty {
            return try GoogleServiceAccountCredentials(jsonPath: path)
        }
        if let path = environment["GOOGLE_APPLICATION_CREDENTIALS"], !path.isEmpty {
            return try GoogleServiceAccountCredentials(jsonPath: path)
        }
        return nil
    }
}

extension GoogleServiceAccountCredentials: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientEmail = try c.decode(String.self, forKey: .clientEmail)
        privateKey = try c.decode(String.self, forKey: .privateKey)
        tokenUri = try c.decode(String.self, forKey: .tokenUri)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientEmail, forKey: .clientEmail)
        try c.encode(privateKey, forKey: .privateKey)
        try c.encode(tokenUri, forKey: .tokenUri)
        try c.encodeIfPresent(projectId, forKey: .projectId)
    }
}

/// OAuth2 access token response from Google's token endpoint.
///
/// Public because both the JWT flow and the workload-identity STS exchange decode it.
public struct GoogleOAuth2TokenResponse: Codable, Sendable {
    /// The bearer token to send as `Authorization: Bearer …`.
    public let accessToken: String
    /// Lifetime in seconds from issuance.
    public let expiresIn: Int
    /// Always `"Bearer"` in practice.
    public let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
