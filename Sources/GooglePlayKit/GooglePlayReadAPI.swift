import Foundation
import GoogleAuthKit

/// Read operations against the Play Developer API.
///
/// ## Why reads need an edit
/// Almost nothing in the Play publishing API can be read outside an *edit* — tracks, bundles
/// and APKs all live under `/edits/{editId}/…`. An edit is a transaction: it only changes the
/// app when it is **committed**, and it expires on its own after a few days if abandoned.
///
/// ``withReadOnlyEdit(packageName:_:)`` therefore creates an edit, runs the read, and always
/// deletes it — never commits it. Deleting rather than leaking matters: an abandoned edit shows
/// up in the Play Console as a pending change and blocks a human from starting their own edit,
/// so a read that left one behind would be quietly destructive.
extension GooglePlayClient {

    // MARK: - Edits

    /// Creates a new edit session.
    public func createEdit(packageName: String) async throws -> GooglePlayEdit {
        try await post("/applications/\(packageName)/edits")
    }

    /// Fetches an existing edit session.
    public func getEdit(packageName: String, editId: String) async throws -> GooglePlayEdit {
        try await get("/applications/\(packageName)/edits/\(editId)")
    }

    /// Validates an edit without committing it.
    public func validateEdit(packageName: String, editId: String) async throws -> GooglePlayEdit {
        try await post("/applications/\(packageName)/edits/\(editId):validate")
    }

    /// Commits an edit, applying every change made within it.
    @discardableResult
    public func commitEdit(packageName: String, editId: String) async throws -> GooglePlayEdit {
        try await post("/applications/\(packageName)/edits/\(editId):commit")
    }

    /// Deletes an edit, discarding every change made within it.
    public func deleteEdit(packageName: String, editId: String) async throws {
        try await delete("/applications/\(packageName)/edits/\(editId)")
    }

    /// Runs `body` inside a throwaway edit, deleting the edit afterwards whether or not
    /// `body` threw.
    ///
    /// Never commits. Use this for every read path; use ``GooglePlayUploadService`` for writes.
    public func withReadOnlyEdit<T>(
        packageName: String,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let edit = try await createEdit(packageName: packageName)
        do {
            let result = try await body(edit.id)
            try? await deleteEdit(packageName: packageName, editId: edit.id)
            return result
        } catch {
            // Cleanup must not mask the original failure, so its own error is discarded.
            try? await deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }
    }

    // MARK: - Tracks

    /// Lists every track configured for the app, with its current releases.
    ///
    /// This is the "what is live, and at what rollout percentage" question.
    public func listTracks(packageName: String) async throws -> [GooglePlayTrack] {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            let response: GooglePlayTracksResponse = try await get(
                "/applications/\(packageName)/edits/\(editId)/tracks")
            return response.tracks ?? []
        }
    }

    /// Fetches one track and its current releases.
    public func getTrack(packageName: String, track: String) async throws -> GooglePlayTrack {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            try await get("/applications/\(packageName)/edits/\(editId)/tracks/\(track)")
        }
    }

    /// Lists the Android App Bundles uploaded to the app.
    public func listBundles(packageName: String) async throws -> [GooglePlayBundle] {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            let response: GooglePlayBundlesResponse = try await get(
                "/applications/\(packageName)/edits/\(editId)/bundles")
            return response.bundles ?? []
        }
    }

    /// Lists the APKs uploaded to the app.
    public func listApks(packageName: String) async throws -> [GooglePlayApk] {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            let response: GooglePlayApksResponse = try await get("/applications/\(packageName)/edits/\(editId)/apks")
            return response.apks ?? []
        }
    }

    // MARK: - Rollout control

    /// Replaces the releases on a track within a caller-supplied edit.
    ///
    /// Prefer ``updateRollout(packageName:track:userFraction:)`` or
    /// ``haltRollout(packageName:track:)``, which wrap this in their own edit and commit it.
    public func setTrack(packageName: String, editId: String, track: GooglePlayTrack) async throws -> GooglePlayTrack {
        try await put("/applications/\(packageName)/edits/\(editId)/tracks/\(track.track)", body: track)
    }

    /// Changes the staged-rollout fraction of the in-progress release on a track, and commits.
    ///
    /// - Parameter userFraction: The new fraction. Play requires `0 < userFraction < 1`
    ///   **exclusive** — a full rollout is a `.completed` release, not a fraction of `1.0`, and
    ///   `0` is not a way to stop one (use ``haltRollout(packageName:track:)``). Play also
    ///   rejects a decrease.
    @discardableResult
    public func updateRollout(
        packageName: String,
        track: String,
        userFraction: Double
    ) async throws -> GooglePlayTrack {
        guard userFraction > 0, userFraction < 1 else {
            throw GoogleAPIError.invalidConfiguration(
                reason: """
                    Google Play: userFraction must be greater than 0 and less than 1 (exclusive), got \
                    \(userFraction). Use a completed release for a full rollout, or haltRollout to stop one.
                    """
            )
        }
        return try await mutateInProgressRelease(packageName: packageName, track: track) { release in
            GooglePlayRelease(
                name: release.name,
                versionCodes: release.versionCodes,
                status: .inProgress,
                userFraction: userFraction,
                releaseNotes: release.releaseNotes
            )
        }
    }

    /// Halts the in-progress staged rollout on a track, and commits.
    ///
    /// The rollout fraction is preserved. Play accepts `userFraction` on a halted release, and
    /// keeping it records how far the rollout had reached — which is what you need in order to
    /// resume from that point rather than restarting.
    @discardableResult
    public func haltRollout(packageName: String, track: String) async throws -> GooglePlayTrack {
        try await mutateInProgressRelease(packageName: packageName, track: track) { release in
            GooglePlayRelease(
                name: release.name,
                versionCodes: release.versionCodes,
                status: .halted,
                userFraction: release.userFraction,
                releaseNotes: release.releaseNotes
            )
        }
    }

    /// Reads the track's in-progress release, rewrites it with `transform`, and commits the edit.
    private func mutateInProgressRelease(
        packageName: String,
        track: String,
        _ transform: (GooglePlayRelease) -> GooglePlayRelease
    ) async throws -> GooglePlayTrack {
        let edit = try await createEdit(packageName: packageName)
        do {
            let current: GooglePlayTrack = try await get(
                "/applications/\(packageName)/edits/\(edit.id)/tracks/\(track)")
            let releases = current.releases ?? []
            guard releases.contains(where: { $0.status == .inProgress }) else {
                throw GoogleAPIError.invalidConfiguration(
                    reason: "Google Play: track '\(track)' has no in-progress release to update")
            }
            // PUT replaces the whole releases array, so every other release has to be sent back
            // untouched. A track routinely carries a completed release alongside an in-progress
            // staged rollout; sending only the transformed one would silently delete the rest.
            let rewritten = releases.map { $0.status == .inProgress ? transform($0) : $0 }
            let updated = try await setTrack(
                packageName: packageName,
                editId: edit.id,
                track: GooglePlayTrack(track: track, releases: rewritten)
            )
            try await commitEdit(packageName: packageName, editId: edit.id)
            return updated
        } catch {
            try? await deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }
    }

    // MARK: - Reviews

    /// Lists recent user reviews. Play only returns reviews from the last week.
    ///
    /// - Parameters:
    ///   - packageName: The app's package name.
    ///   - maxResults: Page size; Play caps this well below 100.
    ///   - translationLanguage: When set, Play adds a translation of each review into this language.
    public func listReviews(
        packageName: String,
        maxResults: Int = 50,
        translationLanguage: String? = nil
    ) async throws -> [GooglePlayReview] {
        var path = "/applications/\(packageName)/reviews?maxResults=\(maxResults)"
        if let translationLanguage, !translationLanguage.isEmpty {
            let encoded =
                translationLanguage.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? translationLanguage
            path += "&translationLanguage=\(encoded)"
        }
        let response: GooglePlayReviewsResponse = try await get(path)
        return response.reviews ?? []
    }

    // MARK: - Data safety

    /// Uploads a Safety Labels declaration from the contents of a Play-format CSV.
    ///
    /// - Important: `applications.dataSafety` is **write-only**. The Play Developer API has no
    ///   endpoint that reads back the current published Data safety declaration, and none that
    ///   distinguishes a published declaration from an unpublished draft — verifying what is
    ///   live has to happen in the Play Console UI.
    public func uploadDataSafetyLabels(packageName: String, safetyLabelsCSV: String) async throws {
        struct Request: Encodable { let safetyLabels: String }
        // A successful response has an empty body, so there is nothing to decode.
        try await postExpectingNoContent(
            "/applications/\(packageName)/dataSafety",
            body: Request(safetyLabels: safetyLabelsCSV)
        )
    }
}
