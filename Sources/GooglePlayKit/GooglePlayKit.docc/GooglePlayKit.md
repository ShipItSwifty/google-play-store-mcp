# ``GooglePlayKit``

A Google Play Developer API v3 client: tracks and staged rollouts, uploaded bundles and APKs,
recent reviews, and the edit → upload → track → commit release workflow.

## Overview

```swift
import GooglePlayKit

let client = try GooglePlayClient(serviceAccountJSONPath: "./service-account.json")

// Everything about the current release, from one edit.
let overview = try await client.releaseOverview(packageName: "com.example.app")
for track in overview.tracks {
    for release in track.releases ?? [] {
        print(track.track, release.status, release.userFraction ?? 1)
    }
}
```

Keep one ``GooglePlayClient`` for the life of your process. It owns the OAuth2 token cache, so
reusing it saves a JWT signature and a token exchange on every call.

Almost every Play read and write happens inside an *edit*. Read <doc:EditLifecycle> before
building on the lower-level edit methods.

## Topics

### Essentials

- ``GooglePlayClient``
- <doc:EditLifecycle>
- <doc:Releasing>

### Reading release state

- ``GooglePlayClient/releaseOverview(packageName:)``
- ``GooglePlayClient/listTracks(packageName:)``
- ``GooglePlayClient/getTrack(packageName:track:)``
- ``GooglePlayClient/listBundles(packageName:)``
- ``GooglePlayClient/listApks(packageName:)``
- ``GooglePlayClient/listReviews(packageName:maxResults:translationLanguage:scanLimit:where:)``

### Releasing and rollout control

- ``GooglePlayUploadService``
- ``GooglePlayClient/promoteRelease(packageName:fromTrack:toTrack:versionCodes:status:userFraction:releaseName:releaseNotes:commitOptions:)``
- ``GooglePlayClient/updateRollout(packageName:track:userFraction:commitOptions:)``
- ``GooglePlayClient/haltRollout(packageName:track:commitOptions:)``
- ``GooglePlayClient/resumeRollout(packageName:track:userFraction:commitOptions:)``
- ``GooglePlayClient/completeRollout(packageName:track:commitOptions:)``
- ``GooglePlayCommitOptions``
- ``GooglePlayClient/uploadDataSafetyLabels(packageName:safetyLabelsCSV:)``

### Replying to reviews

- ``GooglePlayClient/replyToReview(packageName:reviewId:replyText:)``
- ``GooglePlayReviewReplyResult``

### Reliability

- ``GooglePlayRetryPolicy``

### Working with edits directly

- ``GooglePlayClient/withReadOnlyEdit(packageName:_:)``
- ``GooglePlayClient/withCommittedEdit(packageName:options:_:)``
- ``GooglePlayClient/createEdit(packageName:)``
- ``GooglePlayClient/validateEdit(packageName:editId:)``
- ``GooglePlayClient/commitEdit(packageName:editId:options:)``
- ``GooglePlayClient/deleteEdit(packageName:editId:)``
- ``GooglePlayClient/setTrack(packageName:editId:track:)``

### Models

- ``GooglePlayReleaseOverview``
- ``GooglePlayTrack``
- ``GooglePlayRelease``
- ``GooglePlayCountryTargeting``
- ``GooglePlayReleaseStatus``
- ``GooglePlayReleaseNote``
- ``GooglePlayBundle``
- ``GooglePlayApk``
- ``GooglePlayReview``
- ``GooglePlayReviewComment``
- ``GooglePlayTimestamp``
- ``GooglePlayDeviceMetadata``
- ``GooglePlayEdit``
