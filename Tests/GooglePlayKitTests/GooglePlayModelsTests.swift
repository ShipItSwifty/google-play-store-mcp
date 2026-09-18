import Foundation
import Testing

@testable import GooglePlayKit

/// The DTOs' custom `public init`s exist for callers assembling values directly (tests, and
/// downstream consumers building requests), separately from the compiler-synthesized
/// `Codable` decode path that the read/write API tests already exercise. This suite exists to
/// cover those inits.
@Suite("Google Play model inits")
struct GooglePlayModelsTests {

    @Test("GooglePlayEdit")
    func edit() {
        let edit = GooglePlayEdit(id: "edit-1", expiryTimeSeconds: "1700000000")
        #expect(edit.id == "edit-1")
        #expect(edit.expiryTimeSeconds == "1700000000")

        let noExpiry = GooglePlayEdit(id: "edit-2")
        #expect(noExpiry.expiryTimeSeconds == nil)
    }

    @Test("GooglePlayBundle")
    func bundle() {
        let bundle = GooglePlayBundle(versionCode: 412, sha256: "abc")
        #expect(bundle.versionCode == 412)
        #expect(bundle.sha256 == "abc")

        let noHash = GooglePlayBundle(versionCode: 413)
        #expect(noHash.sha256 == nil)
    }

    @Test("GooglePlayApk and its nested binary")
    func apk() {
        let binary = GooglePlayApk.GooglePlayApkBinary(sha256: "def")
        #expect(binary.sha256 == "def")
        #expect(GooglePlayApk.GooglePlayApkBinary().sha256 == nil)

        let apk = GooglePlayApk(versionCode: 412, sha256: "abc", binary: binary)
        #expect(apk.versionCode == 412)
        #expect(apk.sha256 == "abc")
        #expect(apk.binary?.sha256 == "def")

        let bare = GooglePlayApk(versionCode: 413)
        #expect(bare.sha256 == nil)
        #expect(bare.binary == nil)
    }

    @Test("GooglePlayReleaseNote")
    func releaseNote() {
        let note = GooglePlayReleaseNote(language: "en-US", text: "Faster sync")
        #expect(note.language == "en-US")
        #expect(note.text == "Faster sync")
    }

    @Test("GooglePlayRelease")
    func release() {
        let release = GooglePlayRelease(
            name: "4.2.0",
            versionCodes: ["412"],
            status: .inProgress,
            userFraction: 0.25,
            releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Faster sync")]
        )
        #expect(release.name == "4.2.0")
        #expect(release.versionCodes == ["412"])
        #expect(release.status == .inProgress)
        #expect(release.userFraction == 0.25)
        #expect(release.releaseNotes?.first?.text == "Faster sync")

        let bare = GooglePlayRelease(status: .draft)
        #expect(bare.name == nil)
        #expect(bare.versionCodes == nil)
        #expect(bare.userFraction == nil)
        #expect(bare.releaseNotes == nil)
    }

    @Test("every GooglePlayReleaseStatus case round-trips")
    func releaseStatusCases() {
        let statuses: [GooglePlayReleaseStatus] = [.draft, .inProgress, .halted, .completed]
        for status in statuses {
            #expect(GooglePlayReleaseStatus(rawValue: status.rawValue) == status)
        }
    }

    @Test("GooglePlayTrack")
    func track() {
        let track = GooglePlayTrack(track: "production", releases: [GooglePlayRelease(status: .completed)])
        #expect(track.track == "production")
        #expect(track.releases?.count == 1)

        let bare = GooglePlayTrack(track: "beta")
        #expect(bare.releases == nil)
    }

    @Test("response envelopes")
    func envelopes() {
        let tracks = GooglePlayTracksResponse(tracks: [GooglePlayTrack(track: "beta")])
        #expect(tracks.tracks?.count == 1)
        #expect(GooglePlayTracksResponse().tracks == nil)

        let bundles = GooglePlayBundlesResponse(bundles: [GooglePlayBundle(versionCode: 1)])
        #expect(bundles.bundles?.count == 1)
        #expect(GooglePlayBundlesResponse().bundles == nil)

        let apks = GooglePlayApksResponse(apks: [GooglePlayApk(versionCode: 1)])
        #expect(apks.apks?.count == 1)
        #expect(GooglePlayApksResponse().apks == nil)

        let reviews = GooglePlayReviewsResponse(reviews: [GooglePlayReview(reviewId: "r1")])
        #expect(reviews.reviews?.count == 1)
        #expect(GooglePlayReviewsResponse().reviews == nil)
    }

    @Test("GooglePlayReview and its comments")
    func reviewAndComments() {
        let userComment = GooglePlayReviewComment.UserComment(
            text: "Crashes on launch",
            starRating: 1,
            reviewerLanguage: "en",
            device: "Pixel 8",
            appVersionCode: 412,
            appVersionName: "4.2.0"
        )
        #expect(userComment.text == "Crashes on launch")
        #expect(userComment.starRating == 1)
        #expect(userComment.reviewerLanguage == "en")
        #expect(userComment.device == "Pixel 8")
        #expect(userComment.appVersionCode == 412)
        #expect(userComment.appVersionName == "4.2.0")
        #expect(GooglePlayReviewComment.UserComment().text == nil)

        let developerComment = GooglePlayReviewComment.DeveloperComment(text: "Fixed in 4.2.1")
        #expect(developerComment.text == "Fixed in 4.2.1")
        #expect(GooglePlayReviewComment.DeveloperComment().text == nil)

        let comment = GooglePlayReviewComment(userComment: userComment, developerComment: developerComment)
        #expect(comment.userComment?.text == "Crashes on launch")
        #expect(comment.developerComment?.text == "Fixed in 4.2.1")
        #expect(GooglePlayReviewComment().userComment == nil)

        let review = GooglePlayReview(reviewId: "r1", authorName: "Sam", comments: [comment])
        #expect(review.reviewId == "r1")
        #expect(review.authorName == "Sam")
        #expect(review.comments?.count == 1)

        let bare = GooglePlayReview(reviewId: "r2")
        #expect(bare.authorName == nil)
        #expect(bare.comments == nil)
    }
}
