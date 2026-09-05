import Foundation

// MARK: - Google Play Developer API v3 Models

/// A Google Play edit session. All publishing changes are made within an edit
/// and then committed atomically.
public struct GooglePlayEdit: Codable, Sendable {
    /// Unique edit identifier returned by the Edits API.
    public let id: String
    /// RFC 3339 expiry timestamp for this edit session.
    public let expiryTimeSeconds: String?

    public init(id: String, expiryTimeSeconds: String? = nil) {
        self.id = id
        self.expiryTimeSeconds = expiryTimeSeconds
    }
}

/// An uploaded Android App Bundle.
public struct GooglePlayBundle: Codable, Sendable {
    /// The version code of the uploaded bundle.
    public let versionCode: Int
    /// SHA-256 hash of the bundle.
    public let sha256: String?

    public init(versionCode: Int, sha256: String? = nil) {
        self.versionCode = versionCode
        self.sha256 = sha256
    }
}

/// An uploaded APK.
public struct GooglePlayApk: Codable, Sendable {
    /// The version code of the uploaded APK.
    public let versionCode: Int
    /// SHA-256 hash of the APK.
    public let sha256: String?
    /// Binary information.
    public let binary: GooglePlayApkBinary?

    public init(versionCode: Int, sha256: String? = nil, binary: GooglePlayApkBinary? = nil) {
        self.versionCode = versionCode
        self.sha256 = sha256
        self.binary = binary
    }

    /// The `binary` sub-object Play returns alongside an APK.
    public struct GooglePlayApkBinary: Codable, Sendable {
        public let sha256: String?

        public init(sha256: String? = nil) {
            self.sha256 = sha256
        }
    }
}

/// A release note for a specific language.
public struct GooglePlayReleaseNote: Codable, Sendable {
    /// BCP 47 language tag (e.g. `"en-US"`).
    public let language: String
    /// The release note text (max 500 chars).
    public let text: String

    public init(language: String, text: String) {
        self.language = language
        self.text = text
    }
}

/// Deployment status for a track release.
public enum GooglePlayReleaseStatus: String, Codable, Sendable {
    /// Saved but not yet deployed. Finalize in Play Console.
    case draft
    /// Staged rollout to a fraction of users.
    case inProgress
    /// Paused staged rollout.
    case halted
    /// Full rollout to all users.
    case completed
}

/// A release within a track, tying version codes to a status and release notes.
public struct GooglePlayRelease: Codable, Sendable {
    /// Internal name for this release (optional, used in Play Console UI).
    public let name: String?
    /// Version codes included in this release.
    ///
    /// Absent on a draft release that has no artifact attached yet — a normal state Play returns
    /// for an untouched track — so this is optional. It stays absent when re-encoded, which
    /// matters because the rollout helpers send sibling releases back verbatim.
    public let versionCodes: [String]?
    /// Release status.
    public let status: GooglePlayReleaseStatus
    /// Staged rollout fraction (0.0–1.0). Only meaningful for `.inProgress`.
    public let userFraction: Double?
    /// Per-language release notes.
    public let releaseNotes: [GooglePlayReleaseNote]?

    public init(
        name: String? = nil,
        versionCodes: [String]? = nil,
        status: GooglePlayReleaseStatus,
        userFraction: Double? = nil,
        releaseNotes: [GooglePlayReleaseNote]? = nil
    ) {
        self.name = name
        self.versionCodes = versionCodes
        self.status = status
        self.userFraction = userFraction
        self.releaseNotes = releaseNotes
    }
}

/// A Google Play distribution track (e.g. internal, alpha, beta, production).
public struct GooglePlayTrack: Codable, Sendable {
    /// Track identifier: `"internal"`, `"alpha"`, `"beta"`, `"production"`.
    public let track: String
    /// Current releases on this track.
    public let releases: [GooglePlayRelease]?

    public init(track: String, releases: [GooglePlayRelease]? = nil) {
        self.track = track
        self.releases = releases
    }
}

/// The envelope returned by `edits.tracks.list`.
public struct GooglePlayTracksResponse: Codable, Sendable {
    /// Every track configured for the app, including ones with no active release.
    public let tracks: [GooglePlayTrack]?

    public init(tracks: [GooglePlayTrack]? = nil) {
        self.tracks = tracks
    }
}

/// The envelope returned by `edits.bundles.list`.
public struct GooglePlayBundlesResponse: Codable, Sendable {
    public let bundles: [GooglePlayBundle]?

    public init(bundles: [GooglePlayBundle]? = nil) {
        self.bundles = bundles
    }
}

/// The envelope returned by `edits.apks.list`.
public struct GooglePlayApksResponse: Codable, Sendable {
    public let apks: [GooglePlayApk]?

    public init(apks: [GooglePlayApk]? = nil) {
        self.apks = apks
    }
}

// MARK: - Reviews

/// A user review left on the Play Store listing.
public struct GooglePlayReview: Codable, Sendable {
    /// Opaque review identifier.
    public let reviewId: String
    /// The reviewer's display name, when they have one.
    public let authorName: String?
    /// One entry per revision of the review; the most recent is last.
    public let comments: [GooglePlayReviewComment]?

    public init(reviewId: String, authorName: String? = nil, comments: [GooglePlayReviewComment]? = nil) {
        self.reviewId = reviewId
        self.authorName = authorName
        self.comments = comments
    }
}

/// One revision of a review — either the user's text or the developer's reply.
public struct GooglePlayReviewComment: Codable, Sendable {
    public let userComment: UserComment?
    public let developerComment: DeveloperComment?

    public init(userComment: UserComment? = nil, developerComment: DeveloperComment? = nil) {
        self.userComment = userComment
        self.developerComment = developerComment
    }

    /// The review text a user left, with the metadata needed to triage it.
    public struct UserComment: Codable, Sendable {
        public let text: String?
        public let starRating: Int?
        public let reviewerLanguage: String?
        public let device: String?
        public let appVersionCode: Int?
        public let appVersionName: String?

        public init(
            text: String? = nil,
            starRating: Int? = nil,
            reviewerLanguage: String? = nil,
            device: String? = nil,
            appVersionCode: Int? = nil,
            appVersionName: String? = nil
        ) {
            self.text = text
            self.starRating = starRating
            self.reviewerLanguage = reviewerLanguage
            self.device = device
            self.appVersionCode = appVersionCode
            self.appVersionName = appVersionName
        }
    }

    /// A developer reply to the review.
    public struct DeveloperComment: Codable, Sendable {
        public let text: String?

        public init(text: String? = nil) {
            self.text = text
        }
    }
}

/// The envelope returned by `reviews.list`.
public struct GooglePlayReviewsResponse: Codable, Sendable {
    public let reviews: [GooglePlayReview]?

    public init(reviews: [GooglePlayReview]? = nil) {
        self.reviews = reviews
    }
}
