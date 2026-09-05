import Foundation
import GoogleAuthKit
import Logging

/// Orchestrates the Google Play edit → upload → track → commit workflow.
///
/// This mirrors the transactional model required by the Play Developer API v3:
/// all changes must be made within an edit session and committed atomically.
///
/// ## Workflow
/// ```
/// 1. POST /edits               → create edit (editId)
/// 2. POST /edits/{id}/bundles  → upload AAB
///    or POST /edits/{id}/apks  → upload APK
/// 3. PUT  /edits/{id}/tracks   → assign version codes to a track
/// 4. POST /edits/{id}:commit   → commit changes
/// ```
///
/// ## Usage
/// ```swift
/// let client = try GooglePlayClient(serviceAccountJSONPath: "./service-account.json")
/// let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
/// let versionCode = try await uploader.uploadAndRelease(
///     aabPath: "./build/app-release.aab",
///     track: "internal",
///     releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")],
///     status: .completed
/// )
/// ```
public struct GooglePlayUploadService: Sendable {

    private let client: GooglePlayClient
    private let packageName: String
    private let logger = Logger(label: "GooglePlayKit.UploadService")

    /// Creates a `GooglePlayUploadService`.
    ///
    /// - Parameters:
    ///   - client: Authenticated Google Play client.
    ///   - packageName: Android package name (e.g. `com.example.app`).
    public init(client: GooglePlayClient, packageName: String) {
        self.client = client
        self.packageName = packageName
    }

    /// Full upload-and-release workflow: create edit, upload artifact, assign track, commit.
    ///
    /// - Parameters:
    ///   - aabPath: Path to the `.aab` file. Use `apkPath` instead for APK uploads.
    ///   - apkPath: Path to the `.apk` file. Mutually exclusive with `aabPath`.
    ///   - track: Play Store track (e.g. `"internal"`, `"alpha"`, `"beta"`, `"production"`).
    ///   - releaseName: Internal release name shown in the Play Console.
    ///   - releaseNotes: Per-language release notes.
    ///   - status: Release status (`.completed`, `.inProgress`, `.draft`).
    ///   - userFraction: Rollout fraction (0.0–1.0). Only used with `.inProgress` status.
    /// - Returns: The version code of the uploaded artifact.
    @discardableResult
    public func uploadAndRelease(
        aabPath: String? = nil,
        apkPath: String? = nil,
        track: String,
        releaseName: String? = nil,
        releaseNotes: [GooglePlayReleaseNote] = [],
        status: GooglePlayReleaseStatus = .completed,
        userFraction: Double? = nil
    ) async throws -> Int {
        guard aabPath == nil || apkPath == nil else {
            throw GoogleAPIError.invalidConfiguration(
                reason: "GooglePlayUploadService: provide either aabPath or apkPath, not both")
        }

        // Read the artifact before creating an edit: validates existence, and a missing file
        // then fails without leaving an orphaned edit behind in the Play Console.
        let artifactData: Data
        let isBundle: Bool
        if let aab = aabPath {
            artifactData = try readArtifact(path: aab)
            isBundle = true
        } else if let apk = apkPath {
            artifactData = try readArtifact(path: apk)
            isBundle = false
        } else {
            throw GoogleAPIError.invalidConfiguration(
                reason: "GooglePlayUploadService: provide either aabPath or apkPath")
        }

        // 1. Create edit
        logger.info("Creating Play Store edit for package '\(packageName)'")
        let edit = try await client.createEdit(packageName: packageName)
        logger.info("Created edit: \(edit.id)")

        do {
            // 2. Upload artifact
            let versionCode: Int
            if isBundle {
                versionCode = try await uploadBundleData(editId: edit.id, data: artifactData).versionCode
                logger.info("Uploaded AAB versionCode=\(versionCode)")
            } else {
                versionCode = try await uploadApkData(editId: edit.id, data: artifactData).versionCode
                logger.info("Uploaded APK versionCode=\(versionCode)")
            }

            // 3. Assign to track
            logger.info("Assigning versionCode=\(versionCode) to track '\(track)'")
            try await assignToTrack(
                editId: edit.id,
                track: track,
                versionCode: versionCode,
                releaseName: releaseName,
                releaseNotes: releaseNotes,
                status: status,
                userFraction: userFraction
            )

            // 4. Commit edit
            logger.info("Committing Play Store edit \(edit.id)")
            try await client.commitEdit(packageName: packageName, editId: edit.id)
            logger.info("Play Store edit committed. versionCode=\(versionCode) is live on track '\(track)'")

            return versionCode
        } catch {
            // An uncommitted edit lingers in the Play Console and blocks a human from starting
            // their own, so a failed run cleans up after itself. Cleanup errors are discarded so
            // they cannot mask the failure that actually matters.
            logger.info("Discarding Play Store edit \(edit.id) after a failed upload")
            try? await client.deleteEdit(packageName: packageName, editId: edit.id)
            throw error
        }
    }

    // MARK: - Private

    private func uploadBundleData(editId: String, data: Data) async throws -> GooglePlayBundle {
        let responseData = try await client.uploadBinary(
            path: "/applications/\(packageName)/edits/\(editId)/bundles",
            data: data,
            contentType: "application/octet-stream"
        )
        return try decode(GooglePlayBundle.self, from: responseData, path: "edits/\(editId)/bundles")
    }

    private func uploadApkData(editId: String, data: Data) async throws -> GooglePlayApk {
        let responseData = try await client.uploadBinary(
            path: "/applications/\(packageName)/edits/\(editId)/apks",
            data: data,
            contentType: "application/vnd.android.package-archive"
        )
        return try decode(GooglePlayApk.self, from: responseData, path: "edits/\(editId)/apks")
    }

    private func assignToTrack(
        editId: String,
        track: String,
        versionCode: Int,
        releaseName: String?,
        releaseNotes: [GooglePlayReleaseNote],
        status: GooglePlayReleaseStatus,
        userFraction: Double?
    ) async throws {
        let release = GooglePlayRelease(
            name: releaseName,
            versionCodes: ["\(versionCode)"],
            status: status,
            // Play accepts userFraction only on a staged release — inProgress or halted. Sending
            // it on a completed or draft release is rejected.
            userFraction: (status == .inProgress || status == .halted) ? userFraction : nil,
            releaseNotes: releaseNotes.isEmpty ? nil : releaseNotes
        )
        _ = try await client.setTrack(
            packageName: packageName,
            editId: editId,
            track: GooglePlayTrack(track: track, releases: [release])
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleAPIError.decodingFailed(path: path, type: "\(type)", underlying: error)
        }
    }

    private func readArtifact(path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GoogleAPIError.invalidConfiguration(reason: "Google Play: artifact not found at '\(path)'")
        }
        return try Data(contentsOf: url)
    }
}
