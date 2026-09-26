# Keyless auth from GitHub Actions

Authenticate a GitHub Actions job to Google without storing a service-account key.

## Overview

``WorkloadIdentityFederationClient`` exchanges the job's GitHub OIDC token for a Google access
token in three steps: fetch the OIDC token, trade it at Google's STS endpoint for a federated
token, then impersonate a service account through the IAM Credentials API. No key ever exists,
which is the only option when an organization enforces `iam.disableServiceAccountKeyCreation`.

### One-time Google Cloud setup

1. Create a workload identity pool and an OIDC provider for `https://token.actions.githubusercontent.com`,
   with an attribute condition that pins your repository (for example
   `assertion.repository == "your-org/your-repo"`).
2. Create, or reuse, the service account the job should act as. For Play, invite its email in the
   Play Console under **Users and permissions**.
3. Grant `roles/iam.workloadIdentityUser` on that service account to the principal set for your
   repository, not to the whole pool.

### The workflow

The job needs permission to mint an OIDC token:

```yaml
permissions:
  id-token: write
  contents: read
```

Without it, `ACTIONS_ID_TOKEN_REQUEST_URL` is unset and the first step throws a
``GoogleAPIError/invalidConfiguration(reason:)`` saying so.

### In code

```swift
import GoogleAuthKit

let wif = WorkloadIdentityFederationClient(
    provider: "projects/123456789/locations/global/workloadIdentityPools/github-actions/providers/github",
    serviceAccountEmail: "release@example.iam.gserviceaccount.com"
)
let token = try await wif.cachedOrNewToken()
// Send as `Authorization: Bearer \(token)` to a Google Cloud API.
```

> Important: The impersonated token is `cloud-platform` scoped. That suits Firebase App
> Distribution and most Google Cloud APIs, but the Play Developer API only honours the
> `androidpublisher` scope. Keyless auth for Play needs the impersonation step to request that
> scope, which this client does not do yet.

### Troubleshooting

- **Permission denied at the impersonation step:** the repository's principal lacks
  `roles/iam.workloadIdentityUser` on the service account, or the provider's attribute condition
  rejects the repository.
- **Invalid audience at the STS step:** the `provider` string must be the provider's full resource
  name, with the project *number*, not the project ID.
