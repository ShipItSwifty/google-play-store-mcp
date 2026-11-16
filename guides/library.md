# Libraries

Browse the [DocC API reference](https://shipitswifty.github.io/google-play-store-mcp/), including
the release walkthrough and edit lifecycle. The package requires Swift 6.3 and supports Crypto 4.5.2 through 5.x.

```swift
.package(url: "https://github.com/ShipItSwifty/google-play-store-mcp.git", from: "0.2.1")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "GooglePlayKit", package: "google-play-store-mcp"),
    .product(name: "GoogleAuthKit", package: "google-play-store-mcp"),
])
```

## Library API

```swift
import GoogleAuthKit
import GooglePlayKit

let client = try GooglePlayClient(serviceAccountJSONPath: "./service-account.json")

// Reads — what is live, and to how many users?
for track in try await client.listTracks(packageName: "com.example.app") {
    for release in track.releases ?? [] {
        print(track.track, release.status, release.userFraction ?? 1.0)
    }
}

// Tracks, bundles, and APKs together: one edit, three concurrent reads.
let overview = try await client.releaseOverview(packageName: "com.example.app")
print(overview.bundles.map(\.versionCode).max() ?? 0)

// Writes — upload and release in one committed edit.
let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
let versionCode = try await uploader.uploadAndRelease(
    aabPath: "./build/app-release.aab",
    track: "production",
    releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")],
    status: .inProgress,
    userFraction: 0.1
)

// Rollout control.
// userFraction is exclusive: 0 < f < 1. A full rollout is completeRollout, not 1.0.
try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
// Halting preserves the fraction, so resuming picks up where the rollout stopped.
try await client.haltRollout(packageName: "com.example.app", track: "production")
try await client.resumeRollout(packageName: "com.example.app", track: "production")
try await client.completeRollout(packageName: "com.example.app", track: "production")

// Promote what is on internal to production, without uploading again.
try await client.promoteRelease(packageName: "com.example.app", fromTrack: "internal", toTrack: "production")

// Fail instead of cancelling changes someone else already sent for review (Play's default).
try await client.haltRollout(
    packageName: "com.example.app",
    track: "production",
    commitOptions: GooglePlayCommitOptions(changesInReviewBehavior: .errorIfInReview)
)

// Reviews: filter while paging, then reply (public and immediate).
let oneStar = try await client.listReviews(packageName: "com.example.app", maxResults: 20) {
    $0.latestUserComment?.starRating == 1
}
if let review = oneStar.first {
    try await client.replyToReview(
        packageName: "com.example.app", reviewId: review.reviewId, replyText: "Thanks, fixed in 4.2.1.")
}
```

## Edits are transactions

Almost nothing in the Play publishing API can be read outside an *edit*: tracks, bundles and APKs
all live under `/edits/{editId}/…`. An edit only changes the app when it is **committed**, and an
abandoned one shows up in the Play Console as a pending change that blocks a human from starting
their own.

`withReadOnlyEdit(packageName:_:)` therefore creates an edit, runs the read, and attempts to delete
it — never commits. Deletion failure after a successful read is reported; deletion failure after
a failed read does not replace the original error. Every read helper (`listTracks`, `getTrack`, `listBundles`, `listApks`,
`releaseOverview`) goes through it. Every write (`uploadAndRelease`, the rollout helpers,
`promoteRelease`) deletes its edit if any step fails, including the commit. Calls that are not
edit-scoped (`listReviews`, `replyToReview`) create no edit at all.

## Retries

The client retries idempotent requests (`GET`, `PUT`, `DELETE`) up to three times on a dropped
connection, `408`, `429`, and `500`/`502`/`503`/`504`, backing off from 0.5s and honouring
`Retry-After` up to 8s. It never retries a `POST`, so creating, committing, uploading, and
replying are each sent once. Pass `retryPolicy: .none` to any initializer to turn retries off.

## Errors

Both libraries throw one type, `GoogleAPIError`, so a consumer needs a single mapping to its own
error domain. Its `apiError` case unwraps Google's `{"error":{"message":…,"status":…}}` envelope,
so a 403 reads as `The caller does not have permission (PERMISSION_DENIED)` rather than raw JSON.

## Testing against it

`GooglePlayClient.init(tokenProvider:session:)` is public: pass a canned token and a mocked
`URLSession` to test Play-calling code without RSA signing, a network round trip, or `@testable`.

```swift
let client = GooglePlayClient(tokenProvider: { "test-token" }, session: mockSession)
```
