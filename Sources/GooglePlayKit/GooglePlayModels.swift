import Foundation

// MARK: - Google Play Developer API v3 Models

/// A Google Play edit session. All publishing changes are made within an edit
/// and then committed atomically.
public struct GooglePlayEdit: Codable, Sendable {
    /// Unique edit identifier returned by the Edits API.
    public let id: String
    /// Expiry time in seconds since the Unix epoch, encoded as a string.
    public let expiryTimeSeconds: String?

    public init(id: String, expiryTimeSeconds: String? = nil) {
        self.id = id
        self.expiryTimeSeconds = expiryTimeSeconds
    }
}

/// Query options for `edits.commit`.
///
/// Both map onto Play's own parameters. The defaults reproduce Play's behaviour when neither is
/// sent — which, for ``changesInReviewBehavior``, means a commit **cancels any changes already in
/// review** and resubmits everything. Pass ``ChangesInReviewBehavior/errorIfInReview`` to fail
/// instead when a human's submission is pending.
public struct GooglePlayCommitOptions: Sendable, Equatable {
    /// What Play does when the app already has changes in review.
    public enum ChangesInReviewBehavior: String, Sendable, Codable, CaseIterable {
        /// Cancel the changes in review, then submit everything (Play's default).
        case cancelInReviewAndSubmit = "CANCEL_IN_REVIEW_AND_SUBMIT"
        /// Fail the commit, leaving the edit intact, if changes are already in review.
        case errorIfInReview = "ERROR_IF_IN_REVIEW"
    }

    /// When `true`, and the changes are rejected, they are held until someone sends them for
    /// review from the Play Console instead of being reviewed automatically. Some apps must set
    /// this for a commit to succeed at all.
    public var changesNotSentForReview: Bool
    /// What to do about changes already in review. `nil` leaves Play's default.
    public var changesInReviewBehavior: ChangesInReviewBehavior?

    public init(changesNotSentForReview: Bool = false, changesInReviewBehavior: ChangesInReviewBehavior? = nil) {
        self.changesNotSentForReview = changesNotSentForReview
        self.changesInReviewBehavior = changesInReviewBehavior
    }

    /// Play's own defaults: nothing is added to the commit request.
    public static let `default` = GooglePlayCommitOptions()

    /// The query string appended to the commit path, empty for the defaults.
    var queryString: String {
        var items: [String] = []
        if changesNotSentForReview { items.append("changesNotSentForReview=true") }
        if let changesInReviewBehavior { items.append("changesInReviewBehavior=\(changesInReviewBehavior.rawValue)") }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
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
public enum GooglePlayReleaseStatus: String, Codable, Sendable, CaseIterable {
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
    /// Staged rollout fraction, strictly between 0 and 1, for `.inProgress` or `.halted`.
    public let userFraction: Double?
    /// Per-language release notes.
    public let releaseNotes: [GooglePlayReleaseNote]?
    /// Countries targeted by an in-progress production release.
    public let countryTargeting: GooglePlayCountryTargeting?
    /// In-app update priority (0–5), fixed once the release is rolled out.
    public let inAppUpdatePriority: Int?

    public init(
        name: String? = nil,
        versionCodes: [String]? = nil,
        status: GooglePlayReleaseStatus,
        userFraction: Double? = nil,
        releaseNotes: [GooglePlayReleaseNote]? = nil,
        countryTargeting: GooglePlayCountryTargeting? = nil,
        inAppUpdatePriority: Int? = nil
    ) {
        self.name = name
        self.versionCodes = versionCodes
        self.status = status
        self.userFraction = userFraction
        self.releaseNotes = releaseNotes
        self.countryTargeting = countryTargeting
        self.inAppUpdatePriority = inAppUpdatePriority
    }

    /// A copy with a new status and fraction, every other field carried over.
    ///
    /// Rollout changes go through this so the metadata Play attached to the release (country
    /// targeting, update priority, notes) survives the `PUT` that replaces it.
    public func with(status: GooglePlayReleaseStatus, userFraction: Double?) -> GooglePlayRelease {
        GooglePlayRelease(
            name: name,
            versionCodes: versionCodes,
            status: status,
            userFraction: userFraction,
            releaseNotes: releaseNotes,
            countryTargeting: countryTargeting,
            inAppUpdatePriority: inAppUpdatePriority
        )
    }
}

/// Country restrictions attached to a production release.
public struct GooglePlayCountryTargeting: Codable, Sendable {
    /// Two-letter CLDR country codes, such as `US` and `CA`.
    public let countries: [String]?
    /// Whether countries outside the explicit list are also included.
    public let includeRestOfWorld: Bool?

    public init(countries: [String]? = nil, includeRestOfWorld: Bool? = nil) {
        self.countries = countries
        self.includeRestOfWorld = includeRestOfWorld
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

/// Tracks, bundles, and APKs read from one edit — see
/// ``GooglePlayClient/releaseOverview(packageName:)``.
public struct GooglePlayReleaseOverview: Sendable {
    public let tracks: [GooglePlayTrack]
    public let bundles: [GooglePlayBundle]
    public let apks: [GooglePlayApk]

    public init(tracks: [GooglePlayTrack] = [], bundles: [GooglePlayBundle] = [], apks: [GooglePlayApk] = []) {
        self.tracks = tracks
        self.bundles = bundles
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
        /// The review text, translated when `translationLanguage` was requested.
        public let text: String?
        /// The untranslated text, present only when Play translated ``text``.
        public let originalText: String?
        public let lastModified: GooglePlayTimestamp?
        public let starRating: Int?
        public let reviewerLanguage: String?
        public let device: String?
        /// The Android API level of the reviewer's device.
        public let androidOsVersion: Int?
        public let appVersionCode: Int?
        public let appVersionName: String?
        public let thumbsUpCount: Int?
        public let thumbsDownCount: Int?
        public let deviceMetadata: GooglePlayDeviceMetadata?

        public init(
            text: String? = nil,
            originalText: String? = nil,
            lastModified: GooglePlayTimestamp? = nil,
            starRating: Int? = nil,
            reviewerLanguage: String? = nil,
            device: String? = nil,
            androidOsVersion: Int? = nil,
            appVersionCode: Int? = nil,
            appVersionName: String? = nil,
            thumbsUpCount: Int? = nil,
            thumbsDownCount: Int? = nil,
            deviceMetadata: GooglePlayDeviceMetadata? = nil
        ) {
            self.text = text
            self.originalText = originalText
            self.lastModified = lastModified
            self.starRating = starRating
            self.reviewerLanguage = reviewerLanguage
            self.device = device
            self.androidOsVersion = androidOsVersion
            self.appVersionCode = appVersionCode
            self.appVersionName = appVersionName
            self.thumbsUpCount = thumbsUpCount
            self.thumbsDownCount = thumbsDownCount
            self.deviceMetadata = deviceMetadata
        }
    }

    /// A developer reply to the review.
    public struct DeveloperComment: Codable, Sendable {
        public let text: String?
        public let lastModified: GooglePlayTimestamp?

        public init(text: String? = nil, lastModified: GooglePlayTimestamp? = nil) {
            self.text = text
            self.lastModified = lastModified
        }
    }
}

extension GooglePlayReview {
    /// The most recent revision of the user's review, which is the last user comment.
    public var latestUserComment: GooglePlayReviewComment.UserComment? {
        comments?.compactMap(\.userComment).last
    }

    /// The most recent developer reply, if there is one.
    public var latestDeveloperComment: GooglePlayReviewComment.DeveloperComment? {
        comments?.compactMap(\.developerComment).last
    }
}

/// A point in time as the Play API encodes it: whole seconds (as a string) plus nanoseconds.
public struct GooglePlayTimestamp: Codable, Sendable, Equatable {
    /// Seconds since the Unix epoch. Play encodes this int64 as a string.
    public let seconds: String?
    public let nanos: Int?

    public init(seconds: String? = nil, nanos: Int? = nil) {
        self.seconds = seconds
        self.nanos = nanos
    }

    /// The timestamp as a `Date`, or `nil` when ``seconds`` is missing or not a number.
    public var date: Date? {
        guard let seconds, let whole = Double(seconds) else { return nil }
        return Date(timeIntervalSince1970: whole + Double(nanos ?? 0) / 1_000_000_000)
    }
}

/// Hardware details Play attaches to a review.
public struct GooglePlayDeviceMetadata: Codable, Sendable {
    public let productName: String?
    public let manufacturer: String?
    public let deviceClass: String?
    public let screenWidthPx: Int?
    public let screenHeightPx: Int?
    public let nativePlatform: String?
    public let screenDensityDpi: Int?
    public let glEsVersion: Int?
    public let cpuModel: String?
    public let cpuMake: String?
    public let ramMb: Int?

    public init(
        productName: String? = nil,
        manufacturer: String? = nil,
        deviceClass: String? = nil,
        screenWidthPx: Int? = nil,
        screenHeightPx: Int? = nil,
        nativePlatform: String? = nil,
        screenDensityDpi: Int? = nil,
        glEsVersion: Int? = nil,
        cpuModel: String? = nil,
        cpuMake: String? = nil,
        ramMb: Int? = nil
    ) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.deviceClass = deviceClass
        self.screenWidthPx = screenWidthPx
        self.screenHeightPx = screenHeightPx
        self.nativePlatform = nativePlatform
        self.screenDensityDpi = screenDensityDpi
        self.glEsVersion = glEsVersion
        self.cpuModel = cpuModel
        self.cpuMake = cpuMake
        self.ramMb = ramMb
    }
}

/// The reply Play applied, returned by `reviews.reply`.
public struct GooglePlayReviewReplyResult: Codable, Sendable {
    /// The reply text as Play stored it (HTML tags are stripped).
    public let replyText: String?
    /// When the reply took effect.
    public let lastEdited: GooglePlayTimestamp?

    public init(replyText: String? = nil, lastEdited: GooglePlayTimestamp? = nil) {
        self.replyText = replyText
        self.lastEdited = lastEdited
    }
}

/// The envelope returned by `reviews.reply`.
public struct GooglePlayReviewReplyResponse: Codable, Sendable {
    public let result: GooglePlayReviewReplyResult?

    public init(result: GooglePlayReviewReplyResult? = nil) {
        self.result = result
    }
}

/// Cursor paging returned alongside `reviews.list` results.
public struct GooglePlayTokenPagination: Codable, Sendable {
    /// Pass as `token` to fetch the next page; absent on the last page.
    public let nextPageToken: String?
    public let previousPageToken: String?

    public init(nextPageToken: String? = nil, previousPageToken: String? = nil) {
        self.nextPageToken = nextPageToken
        self.previousPageToken = previousPageToken
    }
}

/// The envelope returned by `reviews.list`.
public struct GooglePlayReviewsResponse: Codable, Sendable {
    public let reviews: [GooglePlayReview]?
    /// Present when more reviews are available than this page returned.
    public let tokenPagination: GooglePlayTokenPagination?

    public init(reviews: [GooglePlayReview]? = nil, tokenPagination: GooglePlayTokenPagination? = nil) {
        self.reviews = reviews
        self.tokenPagination = tokenPagination
    }
}
