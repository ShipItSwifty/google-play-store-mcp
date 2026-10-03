# Uploading and releasing an app

Choose a release status, upload an artifact, and commit a Play edit.

## Overview

Configure a service account with access to the app in Play Console, enable the Google Play
Android Developer API, and keep its JSON key outside source control. Reuse one
``GooglePlayClient`` so its access token cache survives across calls.

### Publish to an internal track

```swift
import GooglePlayKit

let client = try GooglePlayClient(serviceAccountJSONPath: "./service-account.json")
let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
let versionCode = try await uploader.uploadAndRelease(
    aabPath: "./build/app-release.aab",
    track: "internal",
    releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")],
    status: .completed
)
```

Supply exactly one of `aabPath` and `apkPath`. The uploader checks the file before creating an
edit, streams the artifact, assigns its version code to the track, and commits. If a step fails,
it attempts to delete the edit and rethrows the original error. See <doc:EditLifecycle>.

> Important: Uploading replaces the track's releases with the new release. If an app needs
> older artifacts retained for device compatibility, assemble the complete desired track using
> the lower-level edit APIs instead.

### Stage a production release

Use `.inProgress` and a fraction strictly between zero and one for a staged production rollout:

```swift
try await uploader.uploadAndRelease(
    aabPath: "./build/app-release.aab",
    track: "production",
    status: .inProgress,
    userFraction: 0.1
)
try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
try await client.haltRollout(packageName: "com.example.app", track: "production")
```

The rollout helpers preserve sibling releases, country targeting, and in-app update priority.
Halting preserves the current fraction. Updating requires an in-progress release; it cannot
resume a halted release or complete a rollout. Complete or resume it in Play Console, or build a
complete track update within your own edit. A full rollout uses `.completed` with no fraction.

### Commit and publication

A successful commit applies an edit; it does not promise immediate public availability. Review
and publishing settings can delay availability. Read release state after the operation and use
Play Console to check review and publication status. Draft releases are not served to users.

### Handle failures

Catch `GoogleAuthKit.GoogleAPIError` for authentication, request, response, and upload failures.
`apiError` with status code zero indicates a transport or token-provider failure before an HTTP
response. A failed read can also indicate unsuccessful edit cleanup. If a mutation's commit
response is lost, inspect current state before retrying: the commit may already have succeeded.
