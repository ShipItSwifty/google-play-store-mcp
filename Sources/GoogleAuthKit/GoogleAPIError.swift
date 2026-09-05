import Foundation

/// The single error type thrown by ``GoogleAuthKit`` and `GooglePlayKit`.
///
/// One enum spans both modules deliberately: a consumer that maps these onto its own
/// error domain (ShipItSwifty maps them onto `ShipItError`) needs exactly one bridge,
/// not one per module.
public enum GoogleAPIError: Error, Sendable {
    /// A Google API returned a non-2xx HTTP status.
    case apiError(statusCode: Int, body: String)

    /// JWT generation or RSA signing failed (bad key, missing fields, unsupported encoding).
    case jwtGenerationFailed(underlying: any Error)

    /// An artifact upload failed after any retries.
    case uploadFailed(asset: String, reason: String)

    /// A request could not be built, or credentials were missing/invalid.
    case invalidConfiguration(reason: String)

    /// A 2xx response body did not match the model this package expects. Carries the request
    /// path and target type so the mismatch is attributable — Google adds and removes response
    /// fields without notice.
    case decodingFailed(path: String, type: String, underlying: any Error)
}

extension GoogleAPIError: LocalizedError {
    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .apiError(let statusCode, let body):
            let detail = Self.googleErrorDetail(from: body) ?? body
            return "Google API error (\(statusCode)): \(detail)"
        case .jwtGenerationFailed(let underlying):
            return "Google OAuth2 JWT generation failed: \(underlying.localizedDescription)"
        case .uploadFailed(let asset, let reason):
            return "Upload failed for '\(asset)': \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .decodingFailed(let path, let type, let underlying):
            return "Could not decode \(type) from '\(path)': \(underlying.localizedDescription)"
        }
    }

    /// Pulls `error.message` out of Google's standard JSON error envelope.
    ///
    /// Google returns `{"error": {"code": 403, "message": "…", "status": "PERMISSION_DENIED"}}`.
    /// Surfacing just the message keeps a 403 readable instead of burying it in JSON.
    private static func googleErrorDetail(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return nil
        }
        if let status = error["status"] as? String {
            return "\(message) (\(status))"
        }
        return message
    }
}
