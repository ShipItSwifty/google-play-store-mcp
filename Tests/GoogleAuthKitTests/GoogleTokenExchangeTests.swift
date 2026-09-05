import Foundation
import Testing

@testable import GoogleAuthKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Counts token-endpoint calls so caching behaviour is observable.
private actor ExchangeCounter {
    private(set) var count = 0
    private(set) var lastBody: String?

    func record(_ request: URLRequest) {
        count += 1
        lastBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Credentials backed by a throwaway RSA key, so the RS256 signing path runs for real.
private func testCredentials() -> GoogleServiceAccountCredentials {
    GoogleServiceAccountCredentials(
        clientEmail: "ci@example.iam.gserviceaccount.com",
        privateKey: testRSAPrivateKeyPEM,
        tokenUri: "https://oauth2.googleapis.com/token",
        projectId: "example"
    )
}

@Suite("Google OAuth2 token exchange")
struct GoogleTokenExchangeTests {

    @Test("a signed assertion is exchanged for an access token")
    func exchangesAssertionForToken() async throws {
        let counter = ExchangeCounter()
        let generator = GoogleServiceAccountJWTGenerator(credentials: testCredentials()) { request in
            await counter.record(request)
            return (
                Data(#"{"access_token":"ya29.token","expires_in":3600,"token_type":"Bearer"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let token = try await generator.cachedOrNewToken()

        #expect(token == "ya29.token")
        let body = try #require(await counter.lastBody)
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"))
        #expect(body.contains("assertion="))
    }

    @Test("a still-valid token is reused instead of re-signing")
    func cachesToken() async throws {
        let counter = ExchangeCounter()
        let generator = GoogleServiceAccountJWTGenerator(credentials: testCredentials()) { request in
            await counter.record(request)
            return (
                Data(#"{"access_token":"ya29.token","expires_in":3600}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        _ = try await generator.cachedOrNewToken()
        _ = try await generator.cachedOrNewToken()

        #expect(await counter.count == 1)
    }

    @Test("a token inside the 60s guard band is refreshed rather than reused")
    func refreshesNearExpiry() async throws {
        let counter = ExchangeCounter()
        let generator = GoogleServiceAccountJWTGenerator(credentials: testCredentials()) { request in
            await counter.record(request)
            return (
                Data(#"{"access_token":"ya29.token","expires_in":30}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        _ = try await generator.cachedOrNewToken()
        _ = try await generator.cachedOrNewToken()

        #expect(await counter.count == 2)
    }

    @Test("a rejected assertion surfaces Google's error, not a decode failure")
    func rejectedAssertionSurfacesAPIError() async throws {
        let generator = GoogleServiceAccountJWTGenerator(credentials: testCredentials()) { request in
            (
                Data(#"{"error":"invalid_grant","error_description":"Invalid JWT Signature."}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            )
        }

        do {
            _ = try await generator.cachedOrNewToken()
            Issue.record("Expected an API error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("invalid_grant"))
        }
    }

    @Test("a malformed token response is reported as a decoding failure with its path")
    func malformedTokenResponse() async throws {
        let generator = GoogleServiceAccountJWTGenerator(credentials: testCredentials()) { request in
            (
                Data(#"{"unexpected":"shape"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        do {
            _ = try await generator.cachedOrNewToken()
            Issue.record("Expected a decoding failure")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("oauth2/token"))
        }
    }

    @Test("an unusable private key fails as a JWT generation error")
    func badPrivateKeyFailsSigning() async throws {
        let credentials = GoogleServiceAccountCredentials(
            clientEmail: "ci@example.iam.gserviceaccount.com",
            privateKey: "-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----",
            tokenUri: "https://oauth2.googleapis.com/token"
        )
        let generator = GoogleServiceAccountJWTGenerator(credentials: credentials) { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await generator.cachedOrNewToken()
        }
    }

    @Test("the cloudPlatform scope is carried into the assertion for Firebase callers")
    func scopeIsHonoured() async throws {
        let generator = GoogleServiceAccountJWTGenerator(
            credentials: testCredentials(), scope: .cloudPlatform,
            transport: { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })

        let jwt = try await generator.buildJWT()
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        let payload = try #require(base64URLDecodeJSON(String(parts[1])))

        #expect(payload["scope"] as? String == "https://www.googleapis.com/auth/cloud-platform")
    }

    @Test("an invalid token URI is rejected before any request is made")
    func invalidTokenURIRejected() async throws {
        let credentials = GoogleServiceAccountCredentials(
            clientEmail: "ci@example.iam.gserviceaccount.com",
            privateKey: testRSAPrivateKeyPEM,
            tokenUri: ""
        )
        let generator = GoogleServiceAccountJWTGenerator(credentials: credentials) { _ in
            Issue.record("No request should be made for an invalid token URI")
            throw GoogleAPIError.invalidConfiguration(reason: "unreachable")
        }

        await #expect(throws: GoogleAPIError.self) {
            _ = try await generator.cachedOrNewToken()
        }
    }
}

private func base64URLDecodeJSON(_ base64url: String) -> [String: Any]? {
    var base64 =
        base64url
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// Test-only RSA key generated solely for this test target. It is not associated with any Google
// service account or other live credential, and exists only to drive the signing path.
private let testRSAPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDd19chv0wmMdfh
    Bp3FSWdGpx2ap4f22iexPoj0azZxEljSOWCcwNvzm3byQuCcHlXo3Jgkm+nu2+0s
    +qIfQylBkOw1U4YXUlccLfuL6P8454QsOiCkEuLQ0bueLxVpiZI5PJNcpbPZKu5F
    uogs3D9FHTqAPQE+7ufzRNYwZsyn4m19kEavft/vm6/Zyk6n4QN+d7l9OcCKm5a7
    avcb98lj7IL/cUEFlSZgb6AMEolYL3aIsM649ltWIYdKhMZbx+19Ek5rbizX+dJr
    dcYCprFcf+D6t1+hTUHruEetyieNnScfI1bhEKomsnvt5TJqm3n/ahlJbLFEzasS
    q+/S+KuvAgMBAAECggEAMNO3WYmpwIRa7//NTOV1kjLpDKeQAPCOKPBLI4TPdD6m
    Bwsy7P1zy9/tY6/9kM8KeJjI8dHRQM3uG2bEtR3KoFA99RS/oDVyz9R9F5O+TO+E
    A1n94i739h8bbNsPGu35HZjsFEmyVnug+v7txvXpBRTEUgJbWlcp/Tyq6fdOVyrR
    axQOm7BdBn7c/FkObbbH4BncWWYmcF6LFgJxK8A+VdGXvLZqGV0Cv4ihEPOsfki4
    AuMFArkAQajebKW8tKj4aJuE7SelM6zDYT+KWLnsL8RynS0DUJ4INKMOCP5euvgd
    ddaI2orxrvoTxDgXZdA8BFhodXNKgM1CzZd8fX6dQQKBgQD+6E6C0ICSkSQW5F7n
    4g4UUUrOV0rZfhAaSJn7m9Ieep/5BmrcsHejFmxMaroyPwkx4AC2imDT4QzUPiUB
    XQNQyOweD8EEZ847PKQ6ctwYmpANkhhuzo8aBm0/dmNQgdG62+1oGbUEKR7gXeni
    cbTtbxpF+txjdlJhxue+RlEAbwKBgQDey0EdMLZt+UyPWDg2Z+HeBojnt+FmRa77
    aeye/ysI5H2cKuAPfDhapXftMJTg0fpYuIAbWHogkl76/OU1Eq/B60P8inv/7HLG
    b4TNjSRo7u71UnXz7T4eekL9SHV1xkDi80jW4VgTvjRH9Qn4RjcwL6akJSwBGZEh
    uLIm1IoowQKBgQD42/d6QvCjJsvjBYWaQNmaAFtV42cRur8hyet69v9F/lWbmyZM
    2oOSVtvYJwIs99mUNaq8i5BIipgpxZn/IL2R6vaJyruX/3gZ4PQ8k9JIuu0UMqNj
    2ole0RNrN7tx56vID9pRHXfZ3gNk7IrgJj6K50LxOx5ahDOdfcDVxHRkRQKBgQC7
    OLCqOAJF3kaQ+wCZ76gl7PXlS2e1iv9ltPisEB/45BIORxVszeWJfx2Ni9LALpQj
    NEArOqm+b2IzpotykxZxbiP+t91GDkvRJ2vBVEdxir/yFe6bIhWehP2AXQCgDQ7/
    6JOgR1O9m4vRoEBVi6Pa8WAm9jnJXtPQM6Y57UeAwQKBgQDaMv0myNAYTRLinlUw
    1ZlUwl6NqBWygBa9HAVw8sXQLa9Ls1866CsM5TUhRoMCVB1wb5/jikt0QNkoAyV1
    5/s4XxZ+0jubQV5Mb0D8Kqv2uf1C4psaSyxClq4s3WjSi1P833aKevIAq1Gk0z5x
    CLXs+qygZfFfEzGbH4FsyNhcQQ==
    -----END PRIVATE KEY-----
    """
