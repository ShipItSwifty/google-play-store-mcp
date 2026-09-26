# ``GoogleAuthKit``

Google service-account credentials, RS256 JWT → OAuth2 token exchange, and GitHub Actions
Workload Identity Federation.

## Overview

GoogleAuthKit turns a Google Cloud identity into a short-lived bearer token for any Google API.
It is scope-agnostic: the same types back the Play Developer API (``GoogleServiceAccountJWTGenerator/Scope/androidPublisher``),
Firebase App Distribution (``GoogleServiceAccountJWTGenerator/Scope/cloudPlatform``), or any
scope you construct.

It depends only on Foundation and `swift-crypto`. Nothing shells out, so it runs unchanged on
macOS and Linux.

```swift
import GoogleAuthKit

let credentials = try GoogleServiceAccountCredentials(jsonPath: "./service-account.json")
let generator = GoogleServiceAccountJWTGenerator(credentials: credentials, scope: .androidPublisher)
let token = try await generator.cachedOrNewToken()
```

Both token sources cache the access token and reuse it until it is within a minute of expiry, so
keep one instance alive rather than creating one per request.

### Choosing a credential source

| Where the code runs | Use |
|---|---|
| A developer machine, a server, or CI with a key secret | ``GoogleServiceAccountCredentials`` + ``GoogleServiceAccountJWTGenerator`` |
| GitHub Actions calling `cloud-platform`-scoped APIs (for example Firebase), especially where key creation is blocked by org policy | ``WorkloadIdentityFederationClient`` |

See <doc:WorkloadIdentityFederation> for the keyless setup.

### Errors

Every failure is a ``GoogleAPIError``. Its `apiError` case unwraps Google's
`{"error":{"message":…,"status":…}}` envelope, so a consumer needs one mapping into its own error
domain and still gets readable messages.

## Topics

### Service-account keys

- ``GoogleServiceAccountCredentials``
- ``GoogleServiceAccountJWTGenerator``
- ``GoogleOAuth2TokenResponse``

### Keyless authentication

- <doc:WorkloadIdentityFederation>
- ``WorkloadIdentityFederationClient``

### Errors

- ``GoogleAPIError``
