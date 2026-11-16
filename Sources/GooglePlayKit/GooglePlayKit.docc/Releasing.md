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
try await client.resumeRollout(packageName: "com.example.app", track: "production")
try await client.completeRollout(packageName: "com.example.app", track: "production")
```

The rollout helpers preserve sibling releases, country targeting, and in-app update priority.
Halting preserves the current fraction, and resuming restarts at it unless you pass a new one.
Completing turns the staged release (in progress or halted) into a `.completed` release with no
fraction and removes the completed release it supersedes; drafts stay.

### Promote a tested build

Move version codes that are already on one track to another, without uploading again:

```swift
try await client.promoteRelease(
    packageName: "com.example.app",
    fromTrack: "internal",
    toTrack: "production",
    status: .inProgress,
    userFraction: 0.05
)
```

With no `versionCodes`, the source track's completed release is promoted, along with its name and
release notes. A completed promotion replaces the target's completed and staged releases; a
staged promotion keeps the target's completed release and replaces only its staged one.

### Changes already in review

By default, Play cancels any changes already in review when you commit and resubmits them with
yours — including, say, a store listing update a teammate sent for review. To fail instead, pass
commit options to any write:

```swift
try await client.haltRollout(
    packageName: "com.example.app",
    track: "production",
    commitOptions: GooglePlayCommitOptions(changesInReviewBehavior: .errorIfInReview)
)
```

`changesNotSentForReview: true` holds a rejected change until someone sends it for review from
the Play Console; Play requires it for some apps.

### Commit and publication

A successful commit applies an edit; it does not promise immediate public availability. Review
and publishing settings can delay availability. Read release state after the operation and use
Play Console to check review and publication status. Draft releases are not served to users.

### Handle failures

Catch `GoogleAuthKit.GoogleAPIError` for authentication, request, response, and upload failures.
`apiError` with status code zero indicates a transport or token-provider failure before an HTTP
response. A failed read can also indicate unsuccessful edit cleanup.

``GooglePlayClient`` retries idempotent requests (`GET`, `PUT`, `DELETE`) on a dropped connection,
`408`, `429`, and retryable `5xx` responses, under a ``GooglePlayRetryPolicy`` you can pass at
init (`.none` disables it). It never retries a `POST`, so edit creation, commits, and uploads are
sent once. If a commit response is lost, inspect current state before retrying: the commit may
already have succeeded.
