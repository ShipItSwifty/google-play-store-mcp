# Libraries

```swift
.package(url: "https://github.com/ShipItSwifty/google-play-store-mcp.git", from: "0.1.0")
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
    track: "internal",
    releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")],
    status: .inProgress,
    userFraction: 0.1
)

// Rollout control.
// userFraction is exclusive: 0 < f < 1. A full rollout is a .completed release, not 1.0.
try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
// Halting preserves the fraction, so you know where the rollout stopped.
try await client.haltRollout(packageName: "com.example.app", track: "production")
```

## Edits are transactions

Almost nothing in the Play publishing API can be read outside an *edit*: tracks, bundles and APKs
all live under `/edits/{editId}/…`. An edit only changes the app when it is **committed**, and an
abandoned one shows up in the Play Console as a pending change that blocks a human from starting
their own.

`withReadOnlyEdit(packageName:_:)` therefore creates an edit, runs the read, and always deletes
it — never commits. Every read helper (`listTracks`, `getTrack`, `listBundles`, `listApks`,
`releaseOverview`) goes through it, and `GooglePlayUploadService` deletes its edit if the upload
fails partway. Reads that are not edit-scoped (`listReviews`) create no edit at all.

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
