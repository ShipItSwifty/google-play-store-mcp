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

### Reading release state

- ``GooglePlayClient/releaseOverview(packageName:)``
- ``GooglePlayClient/listTracks(packageName:)``
- ``GooglePlayClient/getTrack(packageName:track:)``
- ``GooglePlayClient/listBundles(packageName:)``
- ``GooglePlayClient/listApks(packageName:)``
- ``GooglePlayClient/listReviews(packageName:maxResults:translationLanguage:)``

### Releasing and rollout control

- ``GooglePlayUploadService``
- ``GooglePlayClient/updateRollout(packageName:track:userFraction:)``
- ``GooglePlayClient/haltRollout(packageName:track:)``
- ``GooglePlayClient/uploadDataSafetyLabels(packageName:safetyLabelsCSV:)``

### Working with edits directly

- ``GooglePlayClient/withReadOnlyEdit(packageName:_:)``
- ``GooglePlayClient/createEdit(packageName:)``
- ``GooglePlayClient/validateEdit(packageName:editId:)``
- ``GooglePlayClient/commitEdit(packageName:editId:)``
- ``GooglePlayClient/deleteEdit(packageName:editId:)``
- ``GooglePlayClient/setTrack(packageName:editId:track:)``

### Models

- ``GooglePlayReleaseOverview``
- ``GooglePlayTrack``
- ``GooglePlayRelease``
- ``GooglePlayReleaseStatus``
- ``GooglePlayReleaseNote``
- ``GooglePlayBundle``
- ``GooglePlayApk``
- ``GooglePlayReview``
- ``GooglePlayReviewComment``
- ``GooglePlayEdit``
