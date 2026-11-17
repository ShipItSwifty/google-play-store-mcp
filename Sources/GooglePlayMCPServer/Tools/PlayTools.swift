import Foundation
import GoogleAuthKit
import GooglePlayKit
import MCP

/// The catalog of MCP tools exposed over the Google Play Developer API, and the dispatcher
/// that serves them.
enum PlayTools {

    /// Supplies the authenticated client for one tool call.
    ///
    /// A closure rather than a stored client so credentials are resolved at call time (a clear
    /// error per call beats a server that refuses to start), and so tests can inject a stub.
    typealias ClientProvider = @Sendable () throws -> GooglePlayClient

    /// Whether write tools are advertised, set by `GOOGLE_PLAY_ENABLE_WRITES`.
    ///
    /// Off by default: an agent exploring an app's release state should not be one malformed
    /// argument away from changing a production rollout.
    static func writesEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment["GOOGLE_PLAY_ENABLE_WRITES"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// The package tools fall back to when a call omits `packageName`, from
    /// `GOOGLE_PLAY_PACKAGE_NAME`.
    ///
    /// Most sessions are about one app, and without a default the agent has to ask for (or guess)
    /// the package name on every call.
    static func defaultPackageName(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment["GOOGLE_PLAY_PACKAGE_NAME"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Every tool this server can serve, read tools first.
    static let allSpecs: [ToolSpec] = readSpecs + writeSpecs

    /// The tools advertised to the host, filtered by the write gate.
    static func specs(writesEnabled: Bool) -> [ToolSpec] {
        writesEnabled ? allSpecs : readSpecs
    }

    /// Dispatches one `tools/call` request.
    static func call(
        name: String,
        arguments: [String: Value],
        writesEnabled: Bool,
        defaultPackageName: String? = nil,
        clientProvider: @escaping ClientProvider
    ) async throws -> CallTool.Result {
        guard let spec = specs(writesEnabled: writesEnabled).first(where: { $0.name == name }) else {
            // Distinguish "gated off" from "does not exist" — otherwise a user who forgot the
            // env var sees the same message as one who typo'd a tool name.
            if allSpecs.contains(where: { $0.name == name }) {
                throw GoogleAPIError.invalidConfiguration(
                    reason: """
                        Tool '\(name)' modifies Play Store state and is disabled. Set \
                        GOOGLE_PLAY_ENABLE_WRITES=1 to enable the write tools.
                        """
                )
            }
            throw GoogleAPIError.invalidConfiguration(reason: "Unknown tool '\(name)'.")
        }
        return try await spec.handler(ToolArguments(arguments, defaultPackageName: defaultPackageName), clientProvider)
    }

    // MARK: - Read tools

    /// The most reviews one `play_list_reviews` call returns. Play's week of reviews rarely runs
    /// past this, and it keeps a single tool result a reasonable size for the model.
    static let maxReviews = 500

    /// The most reviews a filtered `play_list_reviews` call fetches while looking for matches, so
    /// a filter that matches nothing on a busy app cannot page through tens of thousands.
    static let maxReviewsScanned = 2_000

    /// Shared by the artifact-listing tools: an app with years of uploads returns hundreds of
    /// bundles, almost none of which matter to a release question.
    private static let artifactLimitArgument = ToolArgument.integer(
        "limit", "Return only the newest N bundles and APKs by version code. Omit for all.", minimum: 1)

    /// Keeps the `limit` highest version codes, oldest first, matching Play's own ordering.
    static func newest<T>(_ items: [T], limit: Int?, versionCode: (T) -> Int) -> [T] {
        guard let limit, items.count > limit else { return items }
        return Array(items.sorted { versionCode($0) < versionCode($1) }.suffix(limit))
    }

    /// Optional in the schema so a configured `GOOGLE_PLAY_PACKAGE_NAME` can stand in for it;
    /// ``ToolArguments/packageName()`` still fails clearly when neither is present.
    private static let packageArgument = ToolArgument.string(
        "packageName",
        "The app's package name, e.g. com.example.app. Optional when the server has GOOGLE_PLAY_PACKAGE_NAME set.")

    static let readSpecs: [ToolSpec] = [
        ToolSpec(
            name: "play_release_overview",
            description: """
                One-call release snapshot for an app: every track with its releases and rollout \
                percentage, plus the uploaded bundles and APKs. Reads all three from a single \
                throwaway edit, so prefer it over calling play_list_tracks, play_list_bundles, and \
                play_list_apks separately.
                """,
            arguments: [packageArgument, artifactLimitArgument]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let limit = try arguments.optionalInt("limit")
            let overview = try await client().releaseOverview(packageName: packageName)
            let bundles = newest(overview.bundles, limit: limit, versionCode: \.versionCode)
            let apks = newest(overview.apks, limit: limit, versionCode: \.versionCode)
            let sections = [
                render(tracks: overview.tracks, packageName: packageName),
                render(bundles: bundles, packageName: packageName),
                render(apks: apks, packageName: packageName),
            ]
            return try .rendered(
                sections.joined(separator: "\n\n"),
                structured: ToolOutput.Overview(
                    packageName: packageName, tracks: overview.tracks, bundles: bundles, apks: apks))
        },

        ToolSpec(
            name: "play_list_tracks",
            description: """
                List every Play Store track for an app with its current releases — version codes, \
                release status, and staged-rollout fraction. This answers "what is live, and to what \
                percentage of users".
                """,
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let tracks = try await client().listTracks(packageName: packageName)
            return try .rendered(
                render(tracks: tracks, packageName: packageName),
                structured: ToolOutput.Tracks(packageName: packageName, tracks: tracks))
        },

        ToolSpec(
            name: "play_get_track",
            description: """
                Fetch one Play Store track and its current releases: version codes, release status, \
                staged-rollout fraction, release name, and release notes. Reads from one throwaway edit \
                that is deleted afterwards. Use it when only one track matters, such as reading a rollout \
                before and after changing it; for every track plus the uploaded artifacts, call \
                play_release_overview once instead.
                """,
            arguments: [
                packageArgument,
                .string("track", "Track name: internal, alpha, beta, or production.", required: true),
            ]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try await client().getTrack(packageName: packageName, track: try arguments.require("track"))
            return try .rendered(
                render(tracks: [track], packageName: packageName),
                structured: ToolOutput.Tracks(packageName: packageName, tracks: [track]))
        },

        ToolSpec(
            name: "play_list_bundles",
            description: """
                List the Android App Bundles (AABs) uploaded for an app, newest version code last, with \
                each bundle's version code and SHA-256. Does not say which track a bundle is on; compare \
                with the tracks for that. Reads from one throwaway edit that is deleted afterwards. When \
                you also need tracks or APKs, call play_release_overview instead, which reads all three \
                from a single edit.
                """,
            arguments: [packageArgument, artifactLimitArgument]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let bundles = newest(
                try await client().listBundles(packageName: packageName),
                limit: try arguments.optionalInt("limit"), versionCode: \.versionCode)
            return try .rendered(
                render(bundles: bundles, packageName: packageName),
                structured: ToolOutput.Bundles(packageName: packageName, bundles: bundles))
        },

        ToolSpec(
            name: "play_list_apks",
            description: """
                List the APKs uploaded for an app, newest version code last, with each APK's version \
                code and SHA-256. Does not say which track an APK is on; compare with the tracks for \
                that. Reads from one throwaway edit that is deleted afterwards. When you also need tracks \
                or bundles, call play_release_overview instead, which reads all three from a single edit.
                """,
            arguments: [packageArgument, artifactLimitArgument]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let apks = newest(
                try await client().listApks(packageName: packageName),
                limit: try arguments.optionalInt("limit"), versionCode: \.versionCode)
            return try .rendered(
                render(apks: apks, packageName: packageName),
                structured: ToolOutput.Apks(packageName: packageName, apks: apks))
        },

        ToolSpec(
            name: "play_list_reviews",
            description: """
                List recent user reviews with star rating, date, device, and app version, paging \
                through Play's results up to maxResults. Filter by stars or app version code to get \
                only the reviews that matter. Google only returns reviews from roughly the last week.
                """,
            arguments: [
                packageArgument,
                .integer(
                    "maxResults", "How many reviews to return (1-\(maxReviews), default 50).",
                    minimum: 1, maximum: maxReviews),
                .string("translationLanguage", "BCP 47 tag to translate reviews into, e.g. en-US."),
                .integer("minStars", "Only reviews rated at least this many stars (1-5).", minimum: 1, maximum: 5),
                .integer("maxStars", "Only reviews rated at most this many stars (1-5).", minimum: 1, maximum: 5),
                .integer("appVersionCode", "Only reviews left on this app version code.", minimum: 1),
                .boolean("unrepliedOnly", "Only reviews with no developer reply yet."),
            ]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let filter = try ReviewFilter(
                minStars: arguments.optionalInt("minStars"),
                maxStars: arguments.optionalInt("maxStars"),
                appVersionCode: arguments.optionalInt("appVersionCode"),
                unrepliedOnly: arguments.bool("unrepliedOnly") ?? false)
            let reviews = try await client().listReviews(
                packageName: packageName,
                maxResults: arguments.int("maxResults", default: 50, max: maxReviews),
                translationLanguage: arguments.string("translationLanguage"),
                scanLimit: filter.isEmpty ? nil : maxReviewsScanned,
                where: filter.isEmpty ? nil : filter.matches
            )
            return try .rendered(
                render(reviews: reviews, packageName: packageName),
                structured: ToolOutput.Reviews(packageName: packageName, reviews: reviews))
        },

        ToolSpec(
            name: "play_validate_edit",
            description: """
                Create a throwaway edit and validate it, reporting whether the app's current state \
                would pass Play's pre-commit checks. The edit is always deleted, never committed.
                """,
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let play = try client()
            let result = try await play.withReadOnlyEdit(packageName: packageName) { editId in
                try await play.validateEdit(packageName: packageName, editId: editId)
            }
            return try .rendered(
                "Edit \(result.id) for \(packageName) validated successfully.",
                structured: ToolOutput.Validation(packageName: packageName, editId: result.id, valid: true))
        },
    ]

    // MARK: - Write tools

    /// Shared by every tool that commits an edit.
    ///
    /// Play's own default cancels whatever is already in review and resubmits it with this
    /// change, which could quietly restart a teammate's store-listing review. The tools default
    /// to failing instead; the agent opts in to Play's behaviour explicitly.
    static let commitArguments: [ToolArgument] = [
        .string(
            "changesInReviewBehavior",
            """
            What to do if the app already has changes in Play review. errorIfInReview (default) fails \
            the call and changes nothing; cancelInReviewAndSubmit cancels that review and resubmits \
            everything together with this change.
            """,
            allowedValues: changesInReviewBehaviors),
        .boolean(
            "changesNotSentForReview",
            """
            Set true if Play rejects the commit asking for it: the change is then held until someone \
            sends it for review from the Play Console.
            """),
    ]

    /// The tool-facing names of ``GooglePlayCommitOptions/ChangesInReviewBehavior``.
    static let changesInReviewBehaviors = GooglePlayCommitOptions.ChangesInReviewBehavior.allCases.map { "\($0)" }

    private static let trackArgument = ToolArgument.string(
        "track", "Track name: internal, alpha, beta, or production.", required: true)

    static let writeSpecs: [ToolSpec] = [
        ToolSpec(
            name: "play_upload_and_release",
            description: """
                Upload an AAB or APK and release it to a track in one committed edit. Provide \
                exactly one of aabPath or apkPath. This publishes to real users — confirm the track \
                and rollout fraction before calling.
                """,
            arguments: [
                packageArgument,
                trackArgument,
                .string("aabPath", "Absolute path to the .aab to upload."),
                .string("apkPath", "Absolute path to the .apk to upload."),
                .string("releaseName", "Internal release name shown in the Play Console."),
                .string("releaseNotesLanguage", "BCP 47 tag for the release notes, e.g. en-US."),
                .string("releaseNotesText", "Release note text (max 500 characters)."),
                .string(
                    "status", "Release status. Defaults to completed.",
                    allowedValues: releaseStatuses),
                .number(
                    "userFraction", "Staged rollout fraction, strictly between 0 and 1. Only valid with status inProgress or halted.",
                    exclusiveMinimum: 0, exclusiveMaximum: 1),
            ] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try arguments.require("track")
            let status = try parseStatus(arguments.string("status"))
            let userFraction = try arguments.double("userFraction")
            let commitOptions = try arguments.commitOptions()

            var notes: [GooglePlayReleaseNote] = []
            if let text = arguments.string("releaseNotesText") {
                notes.append(
                    GooglePlayReleaseNote(
                        language: arguments.string("releaseNotesLanguage") ?? "en-US", text: text))
            }

            let uploader = GooglePlayUploadService(client: try client(), packageName: packageName)
            let versionCode = try await uploader.uploadAndRelease(
                aabPath: arguments.string("aabPath"),
                apkPath: arguments.string("apkPath"),
                track: track,
                releaseName: arguments.string("releaseName"),
                releaseNotes: notes,
                status: status,
                userFraction: userFraction,
                commitOptions: commitOptions
            )
            return try .rendered(
                "Released versionCode \(versionCode) to '\(track)' for \(packageName) (\(status.rawValue)).",
                structured: ToolOutput.Release(
                    packageName: packageName, track: track, versionCode: versionCode, status: status,
                    userFraction: userFraction))
        },

        ToolSpec(
            name: "play_promote_release",
            description: """
                Release version codes already on one track to another (e.g. internal to production) \
                and commit, without uploading again. By default promotes the source track's completed \
                release. This publishes to real users — confirm both tracks, status, and fraction first.
                """,
            arguments: [
                packageArgument,
                .string("fromTrack", "Track to promote from, e.g. internal.", required: true),
                .string("toTrack", "Track to promote to, e.g. production.", required: true),
                .stringArray(
                    "versionCodes",
                    "Version codes to promote; they must be in one release on fromTrack. Defaults to its completed release."),
                .string(
                    "status", "Status of the new release on toTrack. Defaults to completed.",
                    allowedValues: releaseStatuses),
                .number(
                    "userFraction", "Staged rollout fraction, strictly between 0 and 1. Required with status inProgress.",
                    exclusiveMinimum: 0, exclusiveMaximum: 1),
                .string("releaseName", "Release name on toTrack. Defaults to the source release's name."),
            ] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let fromTrack = try arguments.require("fromTrack")
            let toTrack = try arguments.require("toTrack")
            let status = try parseStatus(arguments.string("status"))
            let promoted = try await client().promoteRelease(
                packageName: packageName,
                fromTrack: fromTrack,
                toTrack: toTrack,
                versionCodes: arguments.stringList("versionCodes"),
                status: status,
                userFraction: arguments.double("userFraction"),
                releaseName: arguments.string("releaseName"),
                commitOptions: arguments.commitOptions()
            )
            return try .rendered(
                "Promoted from '\(fromTrack)' to '\(toTrack)' for \(packageName).\n\n"
                    + render(tracks: [promoted], packageName: packageName),
                structured: ToolOutput.Rollout(packageName: packageName, track: promoted))
        },

        ToolSpec(
            name: "play_update_rollout",
            description: """
                Change the staged-rollout fraction of the in-progress release on a track, and commit. \
                Play rejects a decrease; halt instead. To reach 100%, use play_complete_rollout.
                """,
            arguments: [
                packageArgument,
                trackArgument,
                .number(
                    "userFraction", "New rollout fraction, strictly between 0 and 1 (exclusive).", required: true,
                    exclusiveMinimum: 0, exclusiveMaximum: 1),
            ] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try arguments.require("track")
            let fraction = try arguments.requireDouble("userFraction")
            let updated = try await client().updateRollout(
                packageName: packageName, track: track, userFraction: fraction,
                commitOptions: arguments.commitOptions())
            return try .rendered(
                "Rollout for '\(track)' in \(packageName) set to \(fraction).",
                structured: ToolOutput.Rollout(packageName: packageName, track: updated))
        },

        ToolSpec(
            name: "play_halt_rollout",
            description: """
                Halt the in-progress staged rollout on a track, and commit. Stops delivery to new users; \
                the fraction is kept so play_resume_rollout can continue from it.
                """,
            arguments: [packageArgument, trackArgument] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try arguments.require("track")
            let halted = try await client().haltRollout(
                packageName: packageName, track: track, commitOptions: arguments.commitOptions())
            return try .rendered(
                "Rollout for '\(track)' in \(packageName) halted.",
                structured: ToolOutput.Rollout(packageName: packageName, track: halted))
        },

        ToolSpec(
            name: "play_resume_rollout",
            description: """
                Resume a halted staged rollout on a track, and commit. Resumes at the fraction it was \
                halted at unless userFraction is given.
                """,
            arguments: [
                packageArgument,
                trackArgument,
                .number(
                    "userFraction", "Fraction to resume at, strictly between 0 and 1. Defaults to the halted fraction.",
                    exclusiveMinimum: 0, exclusiveMaximum: 1),
            ] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try arguments.require("track")
            let resumed = try await client().resumeRollout(
                packageName: packageName, track: track, userFraction: arguments.double("userFraction"),
                commitOptions: arguments.commitOptions())
            return try .rendered(
                "Rollout for '\(track)' in \(packageName) resumed.\n\n" + render(tracks: [resumed], packageName: packageName),
                structured: ToolOutput.Rollout(packageName: packageName, track: resumed))
        },

        ToolSpec(
            name: "play_complete_rollout",
            description: """
                Complete the staged rollout (in progress or halted) on a track, releasing it to 100% of \
                users, and commit. The release it supersedes is removed from the track. Cannot be undone \
                through the API.
                """,
            arguments: [packageArgument, trackArgument] + commitArguments,
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let track = try arguments.require("track")
            let completed = try await client().completeRollout(
                packageName: packageName, track: track, commitOptions: arguments.commitOptions())
            return try .rendered(
                "Rollout for '\(track)' in \(packageName) completed.\n\n"
                    + render(tracks: [completed], packageName: packageName),
                structured: ToolOutput.Rollout(packageName: packageName, track: completed))
        },

        ToolSpec(
            name: "play_reply_to_review",
            description: """
                Publicly reply to a Play Store review, or replace the existing reply. Takes effect \
                immediately. Show the user the exact text and get approval before calling.
                """,
            arguments: [
                packageArgument,
                .string("reviewId", "The reviewId from play_list_reviews.", required: true),
                .string(
                    "replyText", "Plain-text reply, at most \(GooglePlayClient.reviewReplyLimit) characters.",
                    required: true),
            ],
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            let reviewId = try arguments.require("reviewId")
            let result = try await client().replyToReview(
                packageName: packageName, reviewId: reviewId, replyText: try arguments.require("replyText"))
            return try .rendered(
                "Replied to review \(reviewId) for \(packageName): \(result.replyText ?? "")",
                structured: ToolOutput.Reply(
                    packageName: packageName, reviewId: reviewId, replyText: result.replyText,
                    lastEdited: result.lastEdited))
        },

        ToolSpec(
            name: "play_upload_data_safety_labels",
            description: """
                Upload a Data safety (Safety Labels) declaration from Play-format CSV content. \
                Write-only: the Play API cannot read back the current declaration or tell a published \
                one from a draft, so verify the result in the Play Console.
                """,
            arguments: [
                packageArgument,
                .string("safetyLabelsCSV", "The full CSV content of the Safety Labels declaration.", required: true),
            ],
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.packageName()
            try await client().uploadDataSafetyLabels(
                packageName: packageName,
                safetyLabelsCSV: try arguments.require("safetyLabelsCSV")
            )
            return try .rendered(
                """
                Safety Labels uploaded for \(packageName). The API returns no confirmation of \
                the resulting state — verify the Data safety section in the Play Console.
                """,
                structured: ToolOutput.DataSafetyUpload(packageName: packageName, uploaded: true, verifiable: false))
        },
    ]

    // MARK: - Rendering

    /// Every `GooglePlayReleaseStatus` raw value, advertised as the `status` argument's `enum`.
    static let releaseStatuses = ["draft", "inProgress", "halted", "completed"]

    private static func parseStatus(_ raw: String?) throws -> GooglePlayReleaseStatus {
        guard let raw else { return .completed }
        guard let status = GooglePlayReleaseStatus(rawValue: raw) else {
            throw GoogleAPIError.invalidConfiguration(
                reason: "Invalid status '\(raw)'. Expected draft, inProgress, halted, or completed.")
        }
        return status
    }

    static func render(tracks: [GooglePlayTrack], packageName: String) -> String {
        guard !tracks.isEmpty else { return "No tracks configured for \(packageName)." }
        var lines = ["Tracks for \(packageName):"]
        for track in tracks {
            let releases = track.releases ?? []
            if releases.isEmpty {
                lines.append("- \(track.track): no releases")
                continue
            }
            for release in releases {
                var parts = ["- \(track.track): \(release.status.rawValue)"]
                // A draft release can carry no version codes at all; say so rather than "[]".
                if let codes = release.versionCodes, !codes.isEmpty {
                    parts.append("versionCodes=[\(codes.joined(separator: ", "))]")
                } else {
                    parts.append("no version codes")
                }
                if let fraction = release.userFraction {
                    parts.append("rollout=\(Int((fraction * 100).rounded()))%")
                }
                if let name = release.name {
                    parts.append("name='\(name)'")
                }
                lines.append(parts.joined(separator: "  "))
                for note in release.releaseNotes ?? [] {
                    lines.append("    [\(note.language)] \(note.text)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func render(bundles: [GooglePlayBundle], packageName: String) -> String {
        guard !bundles.isEmpty else { return "No bundles uploaded for \(packageName)." }
        let lines = bundles.map { "versionCode \($0.versionCode)  sha256=\($0.sha256 ?? "—")" }
        return "Bundles for \(packageName):\n" + lines.joined(separator: "\n")
    }

    static func render(apks: [GooglePlayApk], packageName: String) -> String {
        guard !apks.isEmpty else { return "No APKs uploaded for \(packageName)." }
        let lines = apks.map { apk in
            "versionCode \(apk.versionCode)  sha256=\(apk.sha256 ?? apk.binary?.sha256 ?? "—")"
        }
        return "APKs for \(packageName):\n" + lines.joined(separator: "\n")
    }

    /// `yyyy-MM-dd` in UTC, so a review's day does not depend on the server's time zone.
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func render(reviews: [GooglePlayReview], packageName: String) -> String {
        guard !reviews.isEmpty else {
            return "No reviews returned for \(packageName). Google only serves reviews from about the last week."
        }
        var lines = ["Reviews for \(packageName):"]
        for review in reviews {
            let user = review.latestUserComment
            let stars = user?.starRating.map { String(repeating: "★", count: max(0, min(5, $0))) } ?? "—"
            var header = "- \(stars)"
            if let date = user?.lastModified?.date { header += " \(dayFormat.string(from: date))" }
            if let name = review.authorName { header += " \(name)" }
            if let version = user?.appVersionName {
                header += " (app \(version)\(user?.appVersionCode.map { ", code \($0)" } ?? ""))"
            }
            if let device = user?.device { header += " on \(device)" }
            if let api = user?.androidOsVersion { header += " API \(api)" }
            if let thumbsUp = user?.thumbsUpCount, thumbsUp > 0 { header += " 👍\(thumbsUp)" }
            header += "  [\(review.reviewId)]"
            lines.append(header)
            if let text = user?.text, !text.isEmpty {
                lines.append("    \(text)")
            }
            if let reply = review.latestDeveloperComment?.text, !reply.isEmpty {
                lines.append("    ↳ replied: \(reply)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The `play_list_reviews` filters, applied while paging.
struct ReviewFilter: Sendable {
    var minStars: Int?
    var maxStars: Int?
    var appVersionCode: Int?
    var unrepliedOnly = false

    init(minStars: Int? = nil, maxStars: Int? = nil, appVersionCode: Int? = nil, unrepliedOnly: Bool = false) throws {
        if let minStars, let maxStars, minStars > maxStars {
            throw GoogleAPIError.invalidConfiguration(
                reason: "minStars (\(minStars)) is greater than maxStars (\(maxStars)); no review could match.")
        }
        self.minStars = minStars
        self.maxStars = maxStars
        self.appVersionCode = appVersionCode
        self.unrepliedOnly = unrepliedOnly
    }

    var isEmpty: Bool { minStars == nil && maxStars == nil && appVersionCode == nil && !unrepliedOnly }

    @Sendable func matches(_ review: GooglePlayReview) -> Bool {
        let user = review.latestUserComment
        if let minStars, (user?.starRating ?? 0) < minStars { return false }
        if let maxStars, (user?.starRating ?? Int.max) > maxStars { return false }
        if let appVersionCode, user?.appVersionCode != appVersionCode { return false }
        if unrepliedOnly, !(review.latestDeveloperComment?.text ?? "").isEmpty { return false }
        return true
    }
}

extension ToolArguments {
    /// The commit options from ``PlayTools/commitArguments``.
    ///
    /// Unlike the library, which keeps Play's default, the tools default to
    /// ``GooglePlayCommitOptions/ChangesInReviewBehavior/errorIfInReview``.
    func commitOptions() throws -> GooglePlayCommitOptions {
        var behavior = GooglePlayCommitOptions.ChangesInReviewBehavior.errorIfInReview
        if let raw = string("changesInReviewBehavior") {
            guard let parsed = GooglePlayCommitOptions.ChangesInReviewBehavior.allCases.first(where: { "\($0)" == raw })
            else {
                throw GoogleAPIError.invalidConfiguration(
                    reason: """
                        Invalid changesInReviewBehavior '\(raw)'. Expected \
                        \(PlayTools.changesInReviewBehaviors.joined(separator: " or ")).
                        """
                )
            }
            behavior = parsed
        }
        return GooglePlayCommitOptions(
            changesNotSentForReview: try bool("changesNotSentForReview") ?? false,
            changesInReviewBehavior: behavior)
    }
}
