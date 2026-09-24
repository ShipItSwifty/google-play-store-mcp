# Edits are transactions

How Play's edit model shapes every call in GooglePlayKit, and the rules the library keeps.

## Overview

Tracks, bundles, and APKs live under `/applications/{package}/edits/{editId}/…`. To read or change
them you open an edit, work inside it, and then either **commit** it, which applies every change
atomically, or **delete** it, which discards them.

An abandoned edit is not harmless. It shows in the Play Console as a pending change and blocks a
person from starting their own edit until it expires. GooglePlayKit therefore never leaves one
behind.

### Reads

``GooglePlayClient/withReadOnlyEdit(packageName:_:)`` creates an edit, runs your closure, and
deletes the edit on both the success and failure paths. It never commits. Every read helper goes
through it.

Each edit costs a create and a delete round trip. When you need several edit-scoped reads, do them
inside one edit. ``GooglePlayClient/releaseOverview(packageName:)`` reads tracks, bundles, and APKs
concurrently inside a single edit:

```swift
let summary = try await client.withReadOnlyEdit(packageName: "com.example.app") { editId in
    async let edit = client.validateEdit(packageName: "com.example.app", editId: editId)
    async let track: GooglePlayTrack = client.get("/applications/com.example.app/edits/\(editId)/tracks/production")
    return try await (edit, track)
}
```

Reviews and Data safety are not edit-scoped and open no edit.

### Writes

``GooglePlayUploadService/uploadAndRelease(aabPath:apkPath:track:releaseName:releaseNotes:status:userFraction:)``
and the rollout helpers open their own edit, make their change, and commit. If any step fails, they
delete the edit before rethrowing. Cleanup errors are discarded so they cannot mask the failure that
matters.

### Staged rollouts

- `userFraction` is only valid on an `inProgress` or `halted` release, and must satisfy
  `0 < userFraction < 1`. A full rollout is a `completed` release, not `1.0`.
- Play rejects *lowering* a fraction. To reduce exposure, halt.
- A track `PUT` replaces the whole `releases` array, so the rollout helpers send every sibling
  release back unchanged. Sending only the modified release would delete the others.

### Limits of the API

- `applications.dataSafety` is write-only. There is no way to read back a published declaration.
- `reviews.list` only returns about the last seven days of reviews.
