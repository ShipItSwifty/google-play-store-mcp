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
        return try await spec.handler(ToolArguments(arguments), clientProvider)
    }

    // MARK: - Read tools

    private static let packageArgument = ToolArgument.string(
        "packageName", "The app's package name, e.g. com.example.app.", required: true)

    static let readSpecs: [ToolSpec] = [
        ToolSpec(
            name: "play_list_tracks",
            description: """
                List every Play Store track for an app with its current releases — version codes, \
                release status, and staged-rollout fraction. This answers "what is live, and to what \
                percentage of users".
                """,
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let tracks = try await client().listTracks(packageName: packageName)
            return .init(content: [.plainText(render(tracks: tracks, packageName: packageName))])
        },

        ToolSpec(
            name: "play_get_track",
            description: "Fetch one Play Store track and its current releases.",
            arguments: [
                packageArgument,
                .string("track", "Track name: internal, alpha, beta, or production.", required: true),
            ]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let track = try await client().getTrack(packageName: packageName, track: try arguments.require("track"))
            return .init(content: [.plainText(render(tracks: [track], packageName: packageName))])
        },

        ToolSpec(
            name: "play_list_bundles",
            description: "List the Android App Bundles (AABs) uploaded for an app, newest version code last.",
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let bundles = try await client().listBundles(packageName: packageName)
            guard !bundles.isEmpty else {
                return .init(content: [.plainText("No bundles uploaded for \(packageName).")])
            }
            let lines = bundles.map { "versionCode \($0.versionCode)  sha256=\($0.sha256 ?? "—")" }
            return .init(content: [.plainText("Bundles for \(packageName):\n" + lines.joined(separator: "\n"))])
        },

        ToolSpec(
            name: "play_list_apks",
            description: "List the APKs uploaded for an app, newest version code last.",
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let apks = try await client().listApks(packageName: packageName)
            guard !apks.isEmpty else {
                return .init(content: [.plainText("No APKs uploaded for \(packageName).")])
            }
            let lines = apks.map { apk in
                "versionCode \(apk.versionCode)  sha256=\(apk.sha256 ?? apk.binary?.sha256 ?? "—")"
            }
            return .init(content: [.plainText("APKs for \(packageName):\n" + lines.joined(separator: "\n"))])
        },

        ToolSpec(
            name: "play_list_reviews",
            description: """
                List recent user reviews with star rating, device, and app version. Google only \
                returns reviews from roughly the last week.
                """,
            arguments: [
                packageArgument,
                .integer("maxResults", "How many reviews to return (1-100, default 50)."),
                .string("translationLanguage", "BCP 47 tag to translate reviews into, e.g. en-US."),
            ]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let reviews = try await client().listReviews(
                packageName: packageName,
                maxResults: arguments.int("maxResults", default: 50),
                translationLanguage: arguments.string("translationLanguage")
            )
            return .init(content: [.plainText(render(reviews: reviews, packageName: packageName))])
        },

        ToolSpec(
            name: "play_validate_edit",
            description: """
                Create a throwaway edit and validate it, reporting whether the app's current state \
                would pass Play's pre-commit checks. The edit is always deleted, never committed.
                """,
            arguments: [packageArgument]
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let play = try client()
            let result = try await play.withReadOnlyEdit(packageName: packageName) { editId in
                try await play.validateEdit(packageName: packageName, editId: editId)
            }
            return .init(content: [.plainText("Edit \(result.id) for \(packageName) validated successfully.")])
        },
    ]

    // MARK: - Write tools

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
                .string("track", "Track name: internal, alpha, beta, or production.", required: true),
                .string("aabPath", "Absolute path to the .aab to upload."),
                .string("apkPath", "Absolute path to the .apk to upload."),
                .string("releaseName", "Internal release name shown in the Play Console."),
                .string("releaseNotesLanguage", "BCP 47 tag for the release notes, e.g. en-US."),
                .string("releaseNotesText", "Release note text (max 500 characters)."),
                .string("status", "draft, inProgress, halted, or completed. Defaults to completed."),
                .number("userFraction", "Staged rollout fraction 0.0-1.0. Only valid with status inProgress."),
            ],
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let track = try arguments.require("track")
            let status = try parseStatus(arguments.string("status"))

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
                userFraction: try? arguments.requireDouble("userFraction")
            )
            return .init(
                content: [
                    .plainText(
                        "Released versionCode \(versionCode) to '\(track)' for \(packageName) (\(status.rawValue)).")
                ])
        },

        ToolSpec(
            name: "play_update_rollout",
            description: """
                Change the staged-rollout fraction of the in-progress release on a track, and commit. \
                Play rejects a decrease.
                """,
            arguments: [
                packageArgument,
                .string("track", "Track name: internal, alpha, beta, or production.", required: true),
                .number("userFraction", "New rollout fraction, 0.0-1.0.", required: true),
            ],
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let track = try arguments.require("track")
            let fraction = try arguments.requireDouble("userFraction")
            _ = try await client().updateRollout(packageName: packageName, track: track, userFraction: fraction)
            return .init(
                content: [.plainText("Rollout for '\(track)' in \(packageName) set to \(fraction).")])
        },

        ToolSpec(
            name: "play_halt_rollout",
            description: "Halt the in-progress staged rollout on a track, and commit. Stops delivery to new users.",
            arguments: [
                packageArgument,
                .string("track", "Track name: internal, alpha, beta, or production.", required: true),
            ],
            isReadOnly: false
        ) { arguments, client in
            let packageName = try arguments.require("packageName")
            let track = try arguments.require("track")
            _ = try await client().haltRollout(packageName: packageName, track: track)
            return .init(content: [.plainText("Rollout for '\(track)' in \(packageName) halted.")])
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
            let packageName = try arguments.require("packageName")
            try await client().uploadDataSafetyLabels(
                packageName: packageName,
                safetyLabelsCSV: try arguments.require("safetyLabelsCSV")
            )
            return .init(
                content: [
                    .plainText(
                        """
                        Safety Labels uploaded for \(packageName). The API returns no confirmation of \
                        the resulting state — verify the Data safety section in the Play Console.
                        """)
                ])
        },
    ]

    // MARK: - Rendering

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
                parts.append("versionCodes=[\(release.versionCodes.joined(separator: ", "))]")
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

    static func render(reviews: [GooglePlayReview], packageName: String) -> String {
        guard !reviews.isEmpty else {
            return "No reviews returned for \(packageName). Google only serves reviews from about the last week."
        }
        var lines = ["Reviews for \(packageName):"]
        for review in reviews {
            // The last comment is the most recent revision of the review.
            let user = review.comments?.compactMap(\.userComment).last
            let stars = user?.starRating.map { String(repeating: "★", count: max(0, min(5, $0))) } ?? "—"
            var header = "- \(stars)"
            if let name = review.authorName { header += " \(name)" }
            if let version = user?.appVersionName { header += " (app \(version))" }
            if let device = user?.device { header += " on \(device)" }
            lines.append(header)
            if let text = user?.text, !text.isEmpty {
                lines.append("    \(text)")
            }
            if let reply = review.comments?.compactMap(\.developerComment).last?.text, !reply.isEmpty {
                lines.append("    ↳ replied: \(reply)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
