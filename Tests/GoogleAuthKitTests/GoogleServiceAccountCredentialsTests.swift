import Foundation
import Testing

@testable import GoogleAuthKit

private let sampleKeyJSON = """
    {
      "type": "service_account",
      "project_id": "example-project",
      "client_email": "ci@example-project.iam.gserviceaccount.com",
      "private_key": "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----\\n",
      "token_uri": "https://oauth2.googleapis.com/token"
    }
    """

@Suite("GoogleServiceAccountCredentials")
struct GoogleServiceAccountCredentialsTests {

    @Test("decodes the snake_case fields of a service account key")
    func decodesServiceAccountKey() throws {
        let credentials = try GoogleServiceAccountCredentials(json: Data(sampleKeyJSON.utf8))

        #expect(credentials.clientEmail == "ci@example-project.iam.gserviceaccount.com")
        #expect(credentials.tokenUri == "https://oauth2.googleapis.com/token")
        #expect(credentials.projectId == "example-project")
        #expect(credentials.privateKey.contains("BEGIN PRIVATE KEY"))
    }

    @Test("a non-service-account JSON gets a message naming the expected fields")
    func wrongJSONShapeExplainsItself() throws {
        // An OAuth client secret is the common mix-up; a bare DecodingError would not say so.
        let clientSecret = #"{"installed":{"client_id":"123.apps.googleusercontent.com"}}"#

        do {
            _ = try GoogleServiceAccountCredentials(json: Data(clientSecret.utf8))
            Issue.record("Expected an invalidConfiguration error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("client_email"))
        }
    }

    @Test("round-trips through Codable")
    func encodesBackToSnakeCase() throws {
        let credentials = try GoogleServiceAccountCredentials(json: Data(sampleKeyJSON.utf8))
        let encoded = try JSONEncoder().encode(credentials)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(json["client_email"] as? String == credentials.clientEmail)
        #expect(json["token_uri"] as? String == credentials.tokenUri)
    }

    @Test("environment resolution prefers raw JSON over either file path")
    func environmentPrefersRawJSON() throws {
        let resolved = try GoogleServiceAccountCredentials.fromEnvironment([
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": sampleKeyJSON,
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": "/nonexistent/key.json",
            "GOOGLE_APPLICATION_CREDENTIALS": "/nonexistent/other.json",
        ])

        #expect(resolved?.clientEmail == "ci@example-project.iam.gserviceaccount.com")
    }

    @Test("environment resolution reads GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH, then falls back to GOOGLE_APPLICATION_CREDENTIALS")
    func environmentReadsKeyFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("key.json")
        try Data(sampleKeyJSON.utf8).write(to: file)

        let viaPlayPath = try GoogleServiceAccountCredentials.fromEnvironment([
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": file.path
        ])
        #expect(viaPlayPath?.projectId == "example-project")

        let viaADC = try GoogleServiceAccountCredentials.fromEnvironment([
            "GOOGLE_APPLICATION_CREDENTIALS": file.path
        ])
        #expect(viaADC?.projectId == "example-project")
    }

    @Test("an empty environment resolves to nil rather than throwing")
    func emptyEnvironmentIsNotAnError() throws {
        #expect(try GoogleServiceAccountCredentials.fromEnvironment([:]) == nil)
    }

    @Test("a set-but-unreadable key path throws instead of looking like no credentials at all")
    func missingKeyFileThrows() throws {
        #expect(throws: GoogleAPIError.self) {
            _ = try GoogleServiceAccountCredentials.fromEnvironment([
                "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": "/nonexistent/key.json"
            ])
        }
    }
}

@Suite("GoogleAPIError")
struct GoogleAPIErrorTests {

    @Test("an API error surfaces Google's message and status, not the JSON envelope")
    func extractsGoogleErrorMessage() {
        let body = """
            {"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}
            """
        let description = GoogleAPIError.apiError(statusCode: 403, body: body).localizedDescription

        #expect(description.contains("The caller does not have permission"))
        #expect(description.contains("PERMISSION_DENIED"))
        #expect(!description.contains("\"error\""))
    }

    @Test("a non-JSON error body is passed through unchanged")
    func fallsBackToRawBody() {
        let description = GoogleAPIError.apiError(statusCode: 502, body: "Bad Gateway").localizedDescription

        #expect(description.contains("502"))
        #expect(description.contains("Bad Gateway"))
    }
}
