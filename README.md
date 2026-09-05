# google-play-store-mcp

Swift clients for Google service-account auth and the Google Play Developer API, plus an MCP
server that exposes Play release state to an AI agent.

Three products:

| Product | What it is |
|---|---|
| `GoogleAuthKit` | Service-account credentials, RS256 JWT → OAuth2 token exchange, and GitHub Actions Workload Identity Federation. Scope-agnostic, so it backs Play, Firebase, and any other Google API. |
| `GooglePlayKit` | Play Developer API v3 client: tracks, staged rollouts, bundles, APKs, reviews, and the edit → upload → track → commit release workflow. |
| `google-play-store-mcp` | An MCP server over the above, read-only by default. |

Cross-platform (macOS and Linux) — everything is `Foundation` + `swift-crypto`; nothing shells out.

## Install (library)

```swift
.package(url: "https://github.com/ShipItSwifty/google-play-store-mcp.git", from: "0.1.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "GooglePlayKit", package: "google-play-store-mcp"),
    .product(name: "GoogleAuthKit", package: "google-play-store-mcp"),
])
```

### Library API

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
try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
try await client.haltRollout(packageName: "com.example.app", track: "production")
```

#### Edits are transactions

Almost nothing in the Play publishing API can be read outside an *edit*: tracks, bundles and APKs
all live under `/edits/{editId}/…`. An edit only changes the app when it is **committed**, and an
abandoned one shows up in the Play Console as a pending change that blocks a human from starting
their own.

`withReadOnlyEdit(packageName:_:)` therefore creates an edit, runs the read, and always deletes
it — never commits. Every read helper (`listTracks`, `getTrack`, `listBundles`, `listApks`) goes
through it, and `GooglePlayUploadService` deletes its edit if the upload fails partway. Reads that
are not edit-scoped (`listReviews`) create no edit at all.

#### Errors

Both libraries throw one type, `GoogleAPIError`, so a consumer needs a single mapping to its own
error domain. Its `apiError` case unwraps Google's `{"error":{"message":…,"status":…}}` envelope,
so a 403 reads as `The caller does not have permission (PERMISSION_DENIED)` rather than raw JSON.

#### Testing against it

`GooglePlayClient.init(tokenProvider:session:)` is public: pass a canned token and a mocked
`URLSession` to test Play-calling code without RSA signing, a network round trip, or `@testable`.

```swift
let client = GooglePlayClient(tokenProvider: { "test-token" }, session: mockSession)
```

## MCP server

### Credentials

Read from the environment, in priority order:

| Variable | Meaning |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Raw service account key JSON |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH` | Path to the key file |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to the key file (Google-wide convention) |

The service account needs Play Developer API access to the app, granted in the Play Console under
**Users and permissions**. Credentials are resolved per tool call, so a credential problem is
reported as a readable tool error instead of the server failing to launch.

### Tools

Read tools are always advertised. Write tools appear only when `GOOGLE_PLAY_ENABLE_WRITES=1` —
an agent exploring release state should not be one malformed argument away from changing a
production rollout.

| Tool | Reads | What it answers |
|---|---|---|
| `play_list_tracks` | ✅ | What is live on every track, and at what rollout percentage |
| `play_get_track` | ✅ | The same, for one track |
| `play_list_bundles` | ✅ | Which AABs have been uploaded |
| `play_list_apks` | ✅ | Which APKs have been uploaded |
| `play_list_reviews` | ✅ | Recent user reviews with rating, device, and app version |
| `play_validate_edit` | ✅ | Would the app's current state pass Play's pre-commit checks |
| `play_upload_and_release` | ❌ | Upload an AAB/APK and release it to a track |
| `play_update_rollout` | ❌ | Change the staged-rollout fraction |
| `play_halt_rollout` | ❌ | Halt an in-progress rollout |
| `play_upload_data_safety_labels` | ❌ | Upload a Safety Labels CSV |

#### What the Play API cannot do

`applications.dataSafety` is **write-only**. There is no endpoint that reads back the current
published Data safety declaration, and none that distinguishes a published declaration from an
unpublished draft — verifying what is live has to happen in the Play Console UI. No MCP server
built on this API can answer that question.

Google also only returns reviews from roughly the last week.

### Run it

```bash
swift build -c release --product google-play-store-mcp
.build/release/google-play-store-mcp --help
```

### Register with a client

```json
{
  "mcpServers": {
    "google-play-store": {
      "command": "/path/to/google-play-store-mcp",
      "env": {
        "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": "/path/to/service-account.json"
      }
    }
  }
}
```

Add `"GOOGLE_PLAY_ENABLE_WRITES": "1"` to that `env` block to enable the write tools.

## Development

```bash
swift build
swift test --enable-code-coverage --no-parallel
scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
```

### Live tests

The default run is fully mocked. To check the client against a real Play Console account
(read-only — it creates and deletes throwaway edits, and publishes nothing):

```bash
GOOGLE_PLAY_TEST_PACKAGE_NAME=com.example.app \
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=./service-account.json \
  swift test --filter LiveGooglePlayTests
```

It skips when those are unset.

### Coverage

`scripts/coverage-gate.sh` enforces a line-coverage floor over product code only. CI sets
`MIN_LINE_COVERAGE: "78"`; actual coverage is ~81%. Raise the floor as coverage climbs.

## Releasing

Tag with bare SemVer — no `v` prefix:

```bash
git tag 0.1.0 && git push origin 0.1.0
```

The release workflow stamps the version into `Entry.swift`, builds a macOS universal binary and a
static Linux binary, attests both, and publishes a GitHub release.

## License

MIT — see [LICENSE](LICENSE).
