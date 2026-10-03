# Claude directory and MCP 2.0

Requirements checked against the official documentation on September 30, 2026.

## Current submission path

Submit this repository as a **Plugin bundle**, with plugin path `plugins/google-play-store`.
The server uses stdio and a local service account key; it has no hosted MCP endpoint to submit
as a separate connector. Claude Code is the current tool surface. Chat can load the skills
but cannot run the local server. Cowork skips this server because its required credential
configuration has no default.

The plugin includes its manifest, README, MIT license, three skills, and a readable launcher.
Users install the server separately and configure a key file through `userConfig`; the launcher
executes `google-play-store-mcp` from their `PATH`. This avoids an absent bundled executable,
platform-specific binaries in the repository, and automatic downloads. External executable
resolution can still receive a reviewer hold; local CLI validation does not prove directory
acceptance. See the [official checklist](https://claude.com/docs/plugins/pre-submission-checklist).

Bundling `.build/release/google-play-store-mcp` in the plugin is not viable: the local release
binary measures 9.6 MiB, while the portal rejects plugin files over 5 MiB. Smaller compiled executables still receive a
reviewer hold. A future bundled distribution needs supported-platform artifacts, size checks, and a repeatable packaging step.

## Submit for review

1. Commit and push the plugin changes to the branch intended for distribution. Set `version` in
   `plugins/google-play-store/.claude-plugin/plugin.json` to the release tag before tagging; the
   release workflow fails if they differ, because the field pins installed plugins.
2. Run `claude plugin validate ./plugins/google-play-store --strict`, and exercise its skills
   in Claude Code with a real account. Local validation checks schema, not directory policy or
   successful Play authentication.
3. Open [the developer portal](https://claude.ai/directory/manage) from the organization that
   should own the listing, using an eligible paid account and a connected GitHub account with
   push access.
4. Select **Plugin bundle**; enter `ShipItSwifty/google-play-store-mcp`, path
   `plugins/google-play-store`, and the chosen branch or tag. The repository must be public
   before publishing. A branch follows new commits; a tag stays on its commit.
5. Run portal **Validate**, resolve blocking findings, then review the listing, data handling,
   contact email, and terms before submitting. The README describes the local process, Google
   endpoints, review data, and optional writes; use that behavior when answering the form.
6. Follow review feedback and publish the approved version. CLI validation is not approval.

Source: [Submit your plugin](https://claude.com/docs/plugins/submit).

## MCP 2.0 status

The stable specification is **2026-07-28**; it has already shipped. Claude's
[plugin announcement](https://claude.com/blog/build-plugins-for-claude) says Claude supports it.
The released SDK in `Package.swift` still advertises a latest protocol of `2025-11-25` and uses
`initialize`. This server therefore does **not** implement MCP 2.0 today. The submission
checklist does not make MCP 2.0 a prerequisite for a local plugin bundle.

Upstream's latest published Swift SDK is currently
[0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases), released May 7, 2026.
Its release does not supply the modern request lifecycle. A stateless HTTP transport by itself
does not implement the 2026 protocol.

The package uses the official SDK 0.12.1 through SemVer. Until upstream
[#276](https://github.com/modelcontextprotocol/swift-sdk/pull/276) supplies arbitrary JSON
experimental capabilities, `CapabilityCompatibleTransport` filters non-string experimental
values from initialization. This server does not use experimental client capabilities; standard
capabilities and tool messages pass through. Wire regression tests cover Codex initialization.
This avoids a revision dependency, which SwiftPM rejects when a consumer installs the libraries
through a version tag.

## Protocol migration work

Upgrade the SDK when it supports both protocol eras, then adapt `Entry.swift` and its wire tests:

| Area | Required work |
|---|---|
| Lifecycle | Accept modern requests without `initialize`; validate per-request protocol version and client capabilities in `_meta`. Preserve legacy handshakes for existing clients. |
| Discovery | Implement `server/discover` with supported versions, capabilities, identity, and instructions. |
| Results | Emit `resultType: "complete"` on modern results, including errors returned as tool results. |
| Catalog | Supply `ttlMs` and `cacheScope`, retain deterministic ordering, and account for the configured write gate. |
| Errors | Use the modern version/capability errors, including `-32022` for unsupported protocol versions. |
| Verification | Exercise discovery, direct tool calls without a handshake, metadata validation, unsupported versions, and legacy clients. |

Source: [2026-07-28 changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
and [version compatibility](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/versioning.mdx).

Stdio remains supported. HTTP is needed for hosted access from chat, not for the protocol upgrade
itself. Existing `GoogleAuthKit`, `GooglePlayKit`, structured outputs, and the cached client can
remain the application layer. Keep edit cleanup and the write gate intact through migration.
MCP Apps and Enterprise Managed Auth are optional extensions, not submission requirements.

## Hosted connector work

To make Play tools available in chat, build and operate an HTTPS Streamable HTTP endpoint,
implement its request headers and validation, and add authentication between Claude and that
endpoint. Google service account authentication currently authenticates the server **to Google**;
it does not authenticate Claude users to a hosted server. A hosted design needs per-user or
per-organization Play access, isolated credentials, and authorization of package names and write
operations. Artifact uploads also need a hosted file flow instead of a path on the user's machine.

Submit the hosted endpoint as an **MCP connector** and reference its URL from the plugin when
that product exists. Review its authentication and tools against the
[connector checklist](https://claude.com/docs/connectors/building/review-criteria).
