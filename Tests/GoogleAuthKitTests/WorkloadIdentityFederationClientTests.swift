import Foundation
import Testing

@testable import GoogleAuthKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records the requests a client makes and answers each from a host-keyed table.
private actor ExchangeRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private func response(_ url: URL?, _ status: Int) -> URLResponse {
    HTTPURLResponse(url: url ?? URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// A transport that answers by host, so a test states the three legs of the exchange declaratively.
private func makeTransport(
    recorder: ExchangeRecorder,
    oidc: (status: Int, body: String) = (200, #"{"value":"github-oidc-token"}"#),
    sts: (status: Int, body: String) = (200, #"{"access_token":"federated-token","expires_in":3600}"#),
    iam: (status: Int, body: String) = (
        200, #"{"accessToken":"impersonated-token","expireTime":"2099-01-01T00:00:00Z"}"#
    )
) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
        await recorder.record(request)
        let host = request.url?.host ?? ""
        let leg: (status: Int, body: String)
        switch host {
        case "sts.googleapis.com": leg = sts
        case "iamcredentials.googleapis.com": leg = iam
        default: leg = oidc
        }
        return (Data(leg.body.utf8), response(request.url, leg.status))
    }
}

/// The GitHub Actions OIDC variables the client reads straight from the process environment.
private func withGitHubOIDCEnvironment(_ body: () async throws -> Void) async rethrows {
    setenv("ACTIONS_ID_TOKEN_REQUEST_URL", "https://token.actions.githubusercontent.com/token", 1)
    setenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "request-token", 1)
    defer {
        unsetenv("ACTIONS_ID_TOKEN_REQUEST_URL")
        unsetenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    }
    try await body()
}

@Suite("WorkloadIdentityFederationClient", .serialized)
struct WorkloadIdentityFederationClientTests {

    private let provider = "projects/123/locations/global/workloadIdentityPools/github-actions/providers/github"
    private let serviceAccount = "ci@example.iam.gserviceaccount.com"

    @Test("the three-step exchange returns the impersonated token")
    func fullExchangeSucceeds() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            let client = WorkloadIdentityFederationClient(
                provider: provider,
                serviceAccountEmail: serviceAccount,
                transport: makeTransport(recorder: recorder)
            )

            let token = try await client.cachedOrNewToken()

            #expect(token == "impersonated-token")
            let requests = await recorder.requests
            #expect(requests.count == 3)
            #expect(requests[0].url?.host == "token.actions.githubusercontent.com")
            #expect(requests[1].url?.host == "sts.googleapis.com")
            #expect(requests[2].url?.host == "iamcredentials.googleapis.com")
        }
    }

    @Test("the OIDC request is audience-bound to the workload identity provider")
    func oidcRequestCarriesAudience() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(recorder: recorder))

            _ = try await client.cachedOrNewToken()

            let oidcRequest = try #require(await recorder.requests.first)
            let query = try #require(oidcRequest.url?.query)
            #expect(query.contains("audience="))
            // Google's STS audience convention for a pool provider.
            #expect(query.contains("iam.googleapis.com"))
            #expect(oidcRequest.value(forHTTPHeaderField: "Authorization") == "Bearer request-token")
        }
    }

    @Test("the STS leg sends the GitHub token as the subject token")
    func stsLegForwardsSubjectToken() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(recorder: recorder))

            _ = try await client.cachedOrNewToken()

            let sts = try #require(await recorder.requests.first { $0.url?.host == "sts.googleapis.com" })
            let body = String(decoding: try #require(sts.httpBody), as: UTF8.self)
            #expect(body.contains("github-oidc-token"))
            #expect(body.contains("token-exchange"))
        }
    }

    @Test("the IAM leg impersonates with the federated token")
    func iamLegUsesFederatedToken() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(recorder: recorder))

            _ = try await client.cachedOrNewToken()

            let iam = try #require(await recorder.requests.first { $0.url?.host == "iamcredentials.googleapis.com" })
            #expect(iam.value(forHTTPHeaderField: "Authorization") == "Bearer federated-token")
            #expect(iam.url?.absoluteString.contains(serviceAccount) == true)
        }
    }

    @Test("a second call reuses the cached token instead of re-running the exchange")
    func tokenIsCached() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(recorder: recorder))

            _ = try await client.cachedOrNewToken()
            _ = try await client.cachedOrNewToken()

            #expect(await recorder.requests.count == 3)
        }
    }

    @Test("a token already expiring is refreshed rather than reused")
    func nearExpiryTokenIsRefreshed() async throws {
        try await withGitHubOIDCEnvironment {
            let recorder = ExchangeRecorder()
            // 30s of life left is inside the 60s guard band, so the second call must re-exchange.
            let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(30))
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(
                    recorder: recorder,
                    iam: (200, #"{"accessToken":"short-lived","expireTime":"\#(soon)"}"#))
            )

            _ = try await client.cachedOrNewToken()
            _ = try await client.cachedOrNewToken()

            #expect(await recorder.requests.count == 6)
        }
    }

    @Test("missing GitHub Actions OIDC variables name the permission the job needs")
    func missingOIDCEnvironmentExplainsItself() async throws {
        unsetenv("ACTIONS_ID_TOKEN_REQUEST_URL")
        unsetenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
        let client = WorkloadIdentityFederationClient(
            provider: provider, serviceAccountEmail: serviceAccount,
            transport: makeTransport(recorder: ExchangeRecorder()))

        do {
            _ = try await client.cachedOrNewToken()
            Issue.record("Expected a configuration error")
        } catch let error as GoogleAPIError {
            #expect(error.localizedDescription.contains("id-token: write"))
        }
    }

    @Test("a denied impersonation points at the workloadIdentityUser binding")
    func impersonationFailureIsActionable() async throws {
        try await withGitHubOIDCEnvironment {
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(
                    recorder: ExchangeRecorder(),
                    iam: (403, #"{"error":{"code":403,"message":"denied","status":"PERMISSION_DENIED"}}"#))
            )

            do {
                _ = try await client.cachedOrNewToken()
                Issue.record("Expected an API error")
            } catch let error as GoogleAPIError {
                #expect(error.localizedDescription.contains("roles/iam.workloadIdentityUser"))
                #expect(error.localizedDescription.contains(serviceAccount))
            }
        }
    }

    @Test("an unparseable expireTime is reported rather than silently treated as expired")
    func badExpireTimeThrows() async throws {
        try await withGitHubOIDCEnvironment {
            let client = WorkloadIdentityFederationClient(
                provider: provider, serviceAccountEmail: serviceAccount,
                transport: makeTransport(
                    recorder: ExchangeRecorder(),
                    iam: (200, #"{"accessToken":"t","expireTime":"not-a-date"}"#))
            )

            await #expect(throws: GoogleAPIError.self) {
                _ = try await client.cachedOrNewToken()
            }
        }
    }
}
