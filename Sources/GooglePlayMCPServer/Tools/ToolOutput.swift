import GooglePlayKit
import MCP

extension CallTool.Result {
    /// A result carrying readable text for the model and the same data as `structuredContent`.
    ///
    /// The text stays the primary content: it is compact, and it is what hosts without
    /// structured-output support show. `structuredContent` gives hosts and scripts that do
    /// support it exact values (full version-code lists, fractions as numbers) with no text to
    /// parse.
    static func rendered<Output: Codable>(_ text: String, structured output: Output) throws -> Self {
        try Self(content: [.plainText(text)], structuredContent: output)
    }
}

/// The `structuredContent` payloads returned by each tool.
///
/// MCP requires structured content to be a JSON object, so list results are wrapped in an object
/// keyed by what they hold, alongside the package they describe.
enum ToolOutput {
    struct Overview: Codable {
        let packageName: String
        let tracks: [GooglePlayTrack]
        let bundles: [GooglePlayBundle]
        let apks: [GooglePlayApk]
    }

    struct Tracks: Codable {
        let packageName: String
        let tracks: [GooglePlayTrack]
    }

    struct Bundles: Codable {
        let packageName: String
        let bundles: [GooglePlayBundle]
    }

    struct Apks: Codable {
        let packageName: String
        let apks: [GooglePlayApk]
    }

    struct Reviews: Codable {
        let packageName: String
        let reviews: [GooglePlayReview]
    }

    struct Validation: Codable {
        let packageName: String
        let editId: String
        let valid: Bool
    }

    struct Release: Codable {
        let packageName: String
        let track: String
        let versionCode: Int
        let status: GooglePlayReleaseStatus
        let userFraction: Double?
    }

    /// The track as Play returned it after a committed rollout change.
    struct Rollout: Codable {
        let packageName: String
        let track: GooglePlayTrack
    }

    struct DataSafetyUpload: Codable {
        let packageName: String
        let uploaded: Bool
        /// Always false: the Play API cannot read a Data safety declaration back.
        let verifiable: Bool
    }
}
