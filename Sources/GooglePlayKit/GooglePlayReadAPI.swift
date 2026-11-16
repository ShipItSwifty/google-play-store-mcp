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
    ///
    /// - Important: With the default `options`, Play cancels any changes already in review and
    ///   resubmits them along with this edit. Pass
    ///   ``GooglePlayCommitOptions/ChangesInReviewBehavior/errorIfInReview`` to fail instead.
    @discardableResult
    public func commitEdit(
        packageName: String,
        editId: String,
        options: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayEdit {
        try await post("/applications/\(packageName)/edits/\(editId):commit\(options.queryString)")
    }

    /// Deletes an edit, discarding every change made within it.
    public func deleteEdit(packageName: String, editId: String) async throws {
        try await delete("/applications/\(packageName)/edits/\(editId)")
    }

    /// Runs `body` inside a throwaway edit, deleting the edit afterwards whether or not
    /// `body` threw. A deletion failure after a successful read is reported; after a failed
    /// read, cleanup is best effort and preserves the original error.
    ///
    /// Never commits. Use this for every read path; use ``GooglePlayUploadService`` for writes.
    public func withReadOnlyEdit<T>(
        packageName: String,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let edit = try await createEdit(packageName: packageName)
        let result: T
        do {
            result = try await body(edit.id)
        } catch {
            // Cleanup must not mask the original failure.
            try? await deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }
        // A successful read must not hide a pending edit if deletion fails.
        try await deleteEdit(packageName: packageName, editId: edit.id)
        return result
    }

    // MARK: - Tracks

    /// Lists every track configured for the app, with its current releases.
    ///
    /// This is the "what is live, and at what rollout percentage" question.
    public func listTracks(packageName: String) async throws -> [GooglePlayTrack] {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            try await fetchTracks(packageName: packageName, editId: editId)
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
            try await fetchBundles(packageName: packageName, editId: editId)
        }
    }

    /// Lists the APKs uploaded to the app.
    public func listApks(packageName: String) async throws -> [GooglePlayApk] {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            try await fetchApks(packageName: packageName, editId: editId)
        }
    }

    /// Reads tracks, bundles, and APKs together, inside one throwaway edit.
    ///
    /// Equivalent to calling ``listTracks(packageName:)``, ``listBundles(packageName:)`` and
    /// ``listApks(packageName:)``, but it opens and deletes one edit instead of three and issues
    /// the three reads concurrently — three round-trip latencies (create, reads, delete) instead
    /// of nine.
    public func releaseOverview(packageName: String) async throws -> GooglePlayReleaseOverview {
        try await withReadOnlyEdit(packageName: packageName) { editId in
            async let tracks = fetchTracks(packageName: packageName, editId: editId)
            async let bundles = fetchBundles(packageName: packageName, editId: editId)
            async let apks = fetchApks(packageName: packageName, editId: editId)
            return GooglePlayReleaseOverview(tracks: try await tracks, bundles: try await bundles, apks: try await apks)
        }
    }

    // Edit-scoped fetches, shared by the single-purpose reads and the overview.

    private func fetchTracks(packageName: String, editId: String) async throws -> [GooglePlayTrack] {
        let response: GooglePlayTracksResponse = try await get("/applications/\(packageName)/edits/\(editId)/tracks")
        return response.tracks ?? []
    }

    private func fetchBundles(packageName: String, editId: String) async throws -> [GooglePlayBundle] {
        let response: GooglePlayBundlesResponse = try await get("/applications/\(packageName)/edits/\(editId)/bundles")
        return response.bundles ?? []
    }

    private func fetchApks(packageName: String, editId: String) async throws -> [GooglePlayApk] {
        let response: GooglePlayApksResponse = try await get("/applications/\(packageName)/edits/\(editId)/apks")
        return response.apks ?? []
    }

    // MARK: - Rollout control

    /// Replaces the releases on a track within a caller-supplied edit.
    ///
    /// Prefer the rollout helpers below, which wrap this in their own edit and commit it.
    public func setTrack(packageName: String, editId: String, track: GooglePlayTrack) async throws -> GooglePlayTrack {
        try await put("/applications/\(packageName)/edits/\(editId)/tracks/\(track.track)", body: track)
    }

    /// Runs `body` inside a new edit and commits it, deleting the edit instead if anything throws.
    ///
    /// The write-side counterpart of ``withReadOnlyEdit(packageName:_:)``. A failed commit also
    /// deletes the edit, so a rejected change never lingers as a pending edit in the Play Console.
    public func withCommittedEdit<T>(
        packageName: String,
        options: GooglePlayCommitOptions = .default,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let edit = try await createEdit(packageName: packageName)
        do {
            let result = try await body(edit.id)
            try await commitEdit(packageName: packageName, editId: edit.id, options: options)
            return result
        } catch {
            // Cleanup must not mask the original failure.
            try? await deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }
    }

    /// Changes the staged-rollout fraction of the in-progress release on a track, and commits.
    ///
    /// - Parameters:
    ///   - packageName: The app's Android package name.
    ///   - track: The track containing the staged release.
    ///   - userFraction: The new fraction. Play requires `0 < userFraction < 1`
    ///     **exclusive** — a full rollout is ``completeRollout(packageName:track:commitOptions:)``,
    ///     not a fraction of `1.0`, and `0` is not a way to stop one (use
    ///     ``haltRollout(packageName:track:commitOptions:)``). Play also rejects a decrease.
    ///   - commitOptions: How the commit treats changes already in review.
    @discardableResult
    public func updateRollout(
        packageName: String,
        track: String,
        userFraction: Double,
        commitOptions: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayTrack {
        try Self.validateFraction(userFraction)
        return try await rewriteReleases(
            packageName: packageName, track: track, from: [.inProgress], action: "update",
            commitOptions: commitOptions
        ) { release in
            release.with(status: .inProgress, userFraction: userFraction)
        }
    }

    /// Halts the in-progress staged rollout on a track, and commits.
    ///
    /// The rollout fraction is preserved. Play accepts `userFraction` on a halted release, and
    /// keeping it records how far the rollout had reached, which is what
    /// ``resumeRollout(packageName:track:userFraction:commitOptions:)`` resumes from.
    @discardableResult
    public func haltRollout(
        packageName: String,
        track: String,
        commitOptions: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayTrack {
        try await rewriteReleases(
            packageName: packageName, track: track, from: [.inProgress], action: "halt",
            commitOptions: commitOptions
        ) { release in
            release.with(status: .halted, userFraction: release.userFraction)
        }
    }

    /// Resumes a halted staged rollout on a track, and commits.
    ///
    /// - Parameters:
    ///   - packageName: The app's Android package name.
    ///   - track: The track containing the halted release.
    ///   - userFraction: The fraction to resume at, strictly between 0 and 1. When `nil`, the
    ///     rollout resumes at the fraction it was halted at; that fails if the halted release
    ///     does not record one.
    ///   - commitOptions: How the commit treats changes already in review.
    @discardableResult
    public func resumeRollout(
        packageName: String,
        track: String,
        userFraction: Double? = nil,
        commitOptions: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayTrack {
        if let userFraction { try Self.validateFraction(userFraction) }
        return try await rewriteReleases(
            packageName: packageName, track: track, from: [.halted], action: "resume",
            commitOptions: commitOptions
        ) { release in
            guard let fraction = userFraction ?? release.userFraction else {
                throw GoogleAPIError.invalidConfiguration(
                    reason: """
                        Google Play: the halted release on '\(track)' records no rollout fraction, so \
                        there is nothing to resume at. Pass userFraction explicitly.
                        """
                )
            }
            return release.with(status: .inProgress, userFraction: fraction)
        }
    }

    /// Completes a staged rollout on a track — in progress or halted — releasing it to every
    /// user, and commits.
    ///
    /// The staged release becomes `completed` and its fraction is dropped. The track's previous
    /// `completed` release is removed, since the newly completed one supersedes it; drafts are
    /// kept.
    @discardableResult
    public func completeRollout(
        packageName: String,
        track: String,
        commitOptions: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayTrack {
        try await rewriteReleases(
            packageName: packageName, track: track, from: [.inProgress, .halted], action: "complete",
            dropping: [.completed], commitOptions: commitOptions
        ) { release in
            release.with(status: .completed, userFraction: nil)
        }
    }

    /// Reads a track, rewrites the releases whose status is in `from`, and commits.
    ///
    /// PUT replaces the whole releases array, so every other release is sent back untouched —
    /// a track routinely carries a completed release alongside an in-progress staged rollout,
    /// and sending only the rewritten one would silently delete the rest. Releases whose status
    /// is in `dropping` (and which are not themselves rewritten) are removed on purpose.
    private func rewriteReleases(
        packageName: String,
        track: String,
        from targets: Set<GooglePlayReleaseStatus>,
        action: String,
        dropping: Set<GooglePlayReleaseStatus> = [],
        commitOptions: GooglePlayCommitOptions,
        _ transform: (GooglePlayRelease) throws -> GooglePlayRelease
    ) async throws -> GooglePlayTrack {
        try await withCommittedEdit(packageName: packageName, options: commitOptions) { editId in
            let current: GooglePlayTrack = try await get("/applications/\(packageName)/edits/\(editId)/tracks/\(track)")
            let releases = current.releases ?? []
            guard releases.contains(where: { targets.contains($0.status) }) else {
                let wanted = targets.map(\.rawValue).sorted().joined(separator: " or ")
                throw GoogleAPIError.invalidConfiguration(
                    reason: "Google Play: track '\(track)' has no \(wanted) release to \(action)")
            }
            let rewritten = try releases.compactMap { release -> GooglePlayRelease? in
                if targets.contains(release.status) { return try transform(release) }
                return dropping.contains(release.status) ? nil : release
            }
            return try await setTrack(
                packageName: packageName, editId: editId, track: GooglePlayTrack(track: track, releases: rewritten))
        }
    }

    static func validateFraction(_ userFraction: Double) throws {
        guard userFraction > 0, userFraction < 1 else {
            throw GoogleAPIError.invalidConfiguration(
                reason: """
                    Google Play: userFraction must be greater than 0 and less than 1 (exclusive), got \
                    \(userFraction). A full rollout is a completed release (completeRollout), and halting is how to stop one.
                    """
            )
        }
    }

    // MARK: - Promotion

    /// Releases version codes already on one track to another track, and commits — the usual
    /// internal → beta → production step, without uploading the artifact again.
    ///
    /// - Parameters:
    ///   - packageName: The app's Android package name.
    ///   - fromTrack: The track to promote from.
    ///   - toTrack: The track to promote to.
    ///   - versionCodes: Which version codes to promote. They must all belong to one release on
    ///     `fromTrack`. When `nil`, the source track's `completed` release is promoted, falling
    ///     back to its `inProgress`, then `halted` release.
    ///   - status: The status of the new release on `toTrack`.
    ///   - userFraction: Required for `.inProgress`, optional for `.halted`, rejected otherwise.
    ///   - releaseName: Defaults to the source release's name.
    ///   - releaseNotes: Defaults to the source release's notes.
    ///   - commitOptions: How the commit treats changes already in review.
    ///
    /// On `toTrack`, the new release replaces releases it supersedes and keeps the rest: a
    /// `completed` release replaces the completed and staged releases, a staged release replaces
    /// the other staged release (keeping the completed one it rolls out over), and a `draft`
    /// replaces the existing draft.
    @discardableResult
    public func promoteRelease(
        packageName: String,
        fromTrack: String,
        toTrack: String,
        versionCodes: [String]? = nil,
        status: GooglePlayReleaseStatus = .completed,
        userFraction: Double? = nil,
        releaseName: String? = nil,
        releaseNotes: [GooglePlayReleaseNote]? = nil,
        commitOptions: GooglePlayCommitOptions = .default
    ) async throws -> GooglePlayTrack {
        guard fromTrack != toTrack else {
            throw GoogleAPIError.invalidConfiguration(
                reason: "Google Play: fromTrack and toTrack are both '\(fromTrack)'; promote to a different track")
        }
        try GooglePlayUploadService.validateRollout(status: status, userFraction: userFraction)

        return try await withCommittedEdit(packageName: packageName, options: commitOptions) { editId in
            async let sourceTrack: GooglePlayTrack = get("/applications/\(packageName)/edits/\(editId)/tracks/\(fromTrack)")
            async let destinationTrack: GooglePlayTrack = get("/applications/\(packageName)/edits/\(editId)/tracks/\(toTrack)")
            let source = try Self.promotionSource(
                in: try await sourceTrack.releases ?? [], track: fromTrack, versionCodes: versionCodes)

            let promoted = GooglePlayRelease(
                name: releaseName ?? source.name,
                versionCodes: versionCodes ?? source.versionCodes,
                status: status,
                userFraction: (status == .inProgress || status == .halted) ? userFraction : nil,
                releaseNotes: releaseNotes ?? source.releaseNotes
            )
            let superseded: Set<GooglePlayReleaseStatus> =
                switch status {
                case .completed: [.completed, .inProgress, .halted]
                case .inProgress, .halted: [.inProgress, .halted]
                case .draft: [.draft]
                }
            let kept = (try await destinationTrack.releases ?? []).filter { !superseded.contains($0.status) }
            return try await setTrack(
                packageName: packageName, editId: editId,
                track: GooglePlayTrack(track: toTrack, releases: kept + [promoted]))
        }
    }

    /// Picks the release on the source track that a promotion copies from.
    static func promotionSource(
        in releases: [GooglePlayRelease],
        track: String,
        versionCodes: [String]?
    ) throws -> GooglePlayRelease {
        let candidates = releases.filter { $0.status != .draft && !($0.versionCodes ?? []).isEmpty }
        if let versionCodes {
            guard !versionCodes.isEmpty else {
                throw GoogleAPIError.invalidConfiguration(reason: "Google Play: versionCodes must not be empty")
            }
            let wanted = Set(versionCodes)
            guard let match = candidates.first(where: { wanted.isSubset(of: Set($0.versionCodes ?? [])) }) else {
                throw GoogleAPIError.invalidConfiguration(
                    reason: """
                        Google Play: no release on '\(track)' contains version codes \
                        \(versionCodes.joined(separator: ", ")). Promote only what is already on the source track.
                        """
                )
            }
            return match
        }
        for status in [GooglePlayReleaseStatus.completed, .inProgress, .halted] {
            let matching = candidates.filter { $0.status == status }
            if let newest = matching.max(by: { Self.highestCode($0) < Self.highestCode($1) }) {
                return newest
            }
        }
        throw GoogleAPIError.invalidConfiguration(
            reason: "Google Play: track '\(track)' has no release with version codes to promote")
    }

    private static func highestCode(_ release: GooglePlayRelease) -> Int {
        (release.versionCodes ?? []).compactMap(Int.init).max() ?? 0
    }

    // MARK: - Reviews

    /// The largest page `reviews.list` is asked for.
    /// ``listReviews(packageName:maxResults:translationLanguage:scanLimit:where:)`` pages past it.
    public static let reviewsPageLimit = 100

    /// Lists recent user reviews, following Play's page tokens until `maxResults` are collected or
    /// the reviews run out. Play only returns reviews from about the last week.
    ///
    /// - Parameters:
    ///   - packageName: The app's package name.
    ///   - maxResults: The total number of reviews to return, across as many pages as that takes.
    ///   - translationLanguage: When set, Play adds a translation of each review into this language.
    ///   - scanLimit: The most reviews to fetch from Play while looking for matches. `nil` scans
    ///     until `maxResults` match or the reviews run out. Only meaningful with `isIncluded`.
    ///   - isIncluded: Keeps only the reviews it returns `true` for. Paging continues past
    ///     non-matching reviews, so a filter for rare reviews still fills `maxResults` when it can.
    public func listReviews(
        packageName: String,
        maxResults: Int = 50,
        translationLanguage: String? = nil,
        scanLimit: Int? = nil,
        where isIncluded: (@Sendable (GooglePlayReview) -> Bool)? = nil
    ) async throws -> [GooglePlayReview] {
        guard maxResults > 0 else { return [] }
        var reviews: [GooglePlayReview] = []
        var scanned = 0
        var token: String?
        var seenTokens: Set<String> = []
        repeat {
            // Unfiltered, ask for exactly what is still needed; filtered, any page could be mostly
            // misses, so ask for full pages up to the scan budget.
            let wanted =
                isIncluded == nil
                ? maxResults - reviews.count
                : (scanLimit.map { $0 - scanned } ?? Self.reviewsPageLimit)
            let page = try await listReviewsPage(
                packageName: packageName,
                maxResults: max(1, min(wanted, Self.reviewsPageLimit)),
                token: token,
                translationLanguage: translationLanguage
            )
            let pageReviews = page.reviews ?? []
            scanned += pageReviews.count
            reviews += isIncluded.map { pageReviews.filter($0) } ?? pageReviews
            token = page.tokenPagination?.nextPageToken
            // An empty page, or a token already followed, would otherwise loop forever.
            if pageReviews.isEmpty { break }
            if let next = token, !seenTokens.insert(next).inserted { break }
            if let scanLimit, scanned >= scanLimit { break }
        } while token != nil && reviews.count < maxResults
        return Array(reviews.prefix(maxResults))
    }

    /// The longest reply Play accepts, in characters.
    public static let reviewReplyLimit = 350

    /// Replies to a review, or replaces the existing reply. The reply is public on the Play Store.
    ///
    /// Not edit-scoped: it takes effect immediately and cannot be staged or rolled back, only
    /// replaced by another reply.
    ///
    /// - Parameters:
    ///   - packageName: The app's Android package name.
    ///   - reviewId: The review's ``GooglePlayReview/reviewId``.
    ///   - replyText: Plain text, at most ``reviewReplyLimit`` characters. Play strips HTML tags.
    @discardableResult
    public func replyToReview(
        packageName: String,
        reviewId: String,
        replyText: String
    ) async throws -> GooglePlayReviewReplyResult {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: replyText must not be empty")
        }
        guard text.count <= Self.reviewReplyLimit else {
            throw GoogleAPIError.invalidConfiguration(
                reason: """
                    Google Play: replyText is \(text.count) characters; Play rejects replies over \
                    \(Self.reviewReplyLimit).
                    """
            )
        }
        struct Request: Encodable { let replyText: String }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let id = reviewId.addingPercentEncoding(withAllowedCharacters: allowed) ?? reviewId
        let response: GooglePlayReviewReplyResponse = try await post(
            "/applications/\(packageName)/reviews/\(id):reply", body: Request(replyText: text))
        return response.result ?? GooglePlayReviewReplyResult(replyText: text)
    }

    /// Fetches one page of `reviews.list`.
    ///
    /// Use this to drive paging yourself;
    /// ``listReviews(packageName:maxResults:translationLanguage:scanLimit:where:)`` already follows
    /// the tokens for you.
    public func listReviewsPage(
        packageName: String,
        maxResults: Int,
        token: String? = nil,
        translationLanguage: String? = nil
    ) async throws -> GooglePlayReviewsResponse {
        var path = "/applications/\(packageName)/reviews?maxResults=\(maxResults)"
        if let token, !token.isEmpty {
            path += "&token=\(Self.queryEncoded(token))"
        }
        if let translationLanguage, !translationLanguage.isEmpty {
            path += "&translationLanguage=\(Self.queryEncoded(translationLanguage))"
        }
        return try await get(path)
    }

    /// Percent-encodes a query value, including the `&`, `=` and `+` that `.urlQueryAllowed`
    /// leaves alone but that would split or corrupt the value — page tokens are opaque and may
    /// contain any of them.
    private static func queryEncoded(_ value: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
