# google-play-store-mcp

Swift clients for Google service-account auth and the Google Play Developer API, plus an MCP
server that exposes Play release state to an AI agent.

Three products:

| Product | What it is |
|---|---|
| `GoogleAuthKit` | Service-account credentials, RS256 JWT → OAuth2 token exchange, and GitHub Actions Workload Identity Federation. Scope-agnostic, so it backs Play, Firebase, and any other Google API. |
| `GooglePlayKit` | Play Developer API v3 client: tracks, staged rollouts, bundles, APKs, reviews, and the edit → upload → track → commit release workflow. |
| `google-play-store-mcp` | An MCP server over the above, read-only by default. |

Cross-platform (macOS and Linux) — everything is `Foundation` + `swift-crypto`; nothing shells out.

## Quick start (MCP server)

1. **Get a service account key with Play access.** See [Service account setup](#service-account-setup).
2. **Build or install the server.**
   ```bash
   swift build -c release --product google-play-store-mcp
   ```
3. **Register it with your agent.**
   ```bash
   scripts/install-mcp.sh --service-account-path /path/to/service-account.json
   ```
4. **Ask it something.**
   > What's live on production for com.example.app, and how are reviews for the new version?

Using Claude Code? The [plugin](#claude-code-plugin-and-skills) registers the server and adds
release-check, rollout, and review-triage skills.

## Contents

- [Install (library)](#install-library)
- [MCP server](#mcp-server): [service account setup](#service-account-setup),
  [credentials](#credentials), [tools](#tools), [register with a client](#register-with-a-client),
  [Claude Code plugin and skills](#claude-code-plugin-and-skills), [example prompts](#example-prompts),
  [troubleshooting](#troubleshooting)
- [Development](#development)
- [Releasing](#releasing)

## Install (library)

```swift
.package(url: "https://github.com/ShipItSwifty/google-play-store-mcp.git", from: "0.1.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "GooglePlayKit", package: "google-play-store-mcp"),
    .product(name: "GoogleAuthKit", package: "google-play-store-mcp"),
])
```

### Library API

```swift
import GoogleAuthKit
import GooglePlayKit

let client = try GooglePlayClient(serviceAccountJSONPath: "./service-account.json")

// Reads — what is live, and to how many users?
for track in try await client.listTracks(packageName: "com.example.app") {
    for release in track.releases ?? [] {
        print(track.track, release.status, release.userFraction ?? 1.0)
    }
}

// Tracks, bundles, and APKs together: one edit, three concurrent reads.
let overview = try await client.releaseOverview(packageName: "com.example.app")
print(overview.bundles.map(\.versionCode).max() ?? 0)

// Writes — upload and release in one committed edit.
let uploader = GooglePlayUploadService(client: client, packageName: "com.example.app")
let versionCode = try await uploader.uploadAndRelease(
    aabPath: "./build/app-release.aab",
    track: "internal",
    releaseNotes: [GooglePlayReleaseNote(language: "en-US", text: "Bug fixes")],
    status: .inProgress,
    userFraction: 0.1
)

// Rollout control.
// userFraction is exclusive: 0 < f < 1. A full rollout is a .completed release, not 1.0.
try await client.updateRollout(packageName: "com.example.app", track: "production", userFraction: 0.5)
// Halting preserves the fraction, so you know where the rollout stopped.
try await client.haltRollout(packageName: "com.example.app", track: "production")
```

#### Edits are transactions

Almost nothing in the Play publishing API can be read outside an *edit*: tracks, bundles and APKs
all live under `/edits/{editId}/…`. An edit only changes the app when it is **committed**, and an
abandoned one shows up in the Play Console as a pending change that blocks a human from starting
their own.

`withReadOnlyEdit(packageName:_:)` therefore creates an edit, runs the read, and always deletes
it — never commits. Every read helper (`listTracks`, `getTrack`, `listBundles`, `listApks`,
`releaseOverview`) goes through it, and `GooglePlayUploadService` deletes its edit if the upload fails partway. Reads that
are not edit-scoped (`listReviews`) create no edit at all.

#### Errors

Both libraries throw one type, `GoogleAPIError`, so a consumer needs a single mapping to its own
error domain. Its `apiError` case unwraps Google's `{"error":{"message":…,"status":…}}` envelope,
so a 403 reads as `The caller does not have permission (PERMISSION_DENIED)` rather than raw JSON.

#### Testing against it

`GooglePlayClient.init(tokenProvider:session:)` is public: pass a canned token and a mocked
`URLSession` to test Play-calling code without RSA signing, a network round trip, or `@testable`.

```swift
let client = GooglePlayClient(tokenProvider: { "test-token" }, session: mockSession)
```

## MCP server

### Service account setup

The server authenticates as a Google Cloud service account that has been invited into your Play
Console account. You do this once per developer account.

1. **Google Cloud:** in any project, enable the **Google Play Android Developer API**
   (`androidpublisher.googleapis.com`).
2. **Google Cloud:** create a service account in that project (it needs no IAM roles), then under
   **Keys → Add key → JSON** download its key file. Treat that file as a secret.
3. **Play Console:** open **Users and permissions → Invite new users**, enter the service account's
   email (`…@….iam.gserviceaccount.com`), and grant it access to the apps you want.
   - Read tools: **View app information and download bulk reports**.
   - Reviews: **Reply to reviews**. The reviews API is gated on it, even for reading.
   - Rollout and release tools: **Release to production, exclude devices, and use Play App
     Signing**, or **Release apps to testing tracks** for non-production tracks.
4. Point the server at the key file (see [Credentials](#credentials)).

New permissions can take a while (sometimes hours) to start working. A `403 PERMISSION_DENIED`
right after inviting the account is usually that delay, not a misconfiguration.

The Play API only manages apps that already exist in the Play Console with at least one uploaded
build. It cannot create a new app.

> Organizations that block key creation (`iam.disableServiceAccountKeyCreation`) can use
> `WorkloadIdentityFederationClient` from `GoogleAuthKit` in GitHub Actions instead. The MCP
> server itself currently reads a JSON key.

### Credentials

Read from the environment, in priority order:

| Variable | Meaning |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Raw service account key JSON |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH` | Path to the key file |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to the key file (Google-wide convention) |

Optional:

| Variable | Meaning |
|---|---|
| `GOOGLE_PLAY_PACKAGE_NAME` | Package used when a tool call omits `packageName`, so a single-app setup never has to be asked for it. An explicit argument always wins. |
| `GOOGLE_PLAY_ENABLE_WRITES` | `1` advertises the write tools (see [Tools](#tools)). |

The service account needs Play Developer API access to the app, granted in the Play Console under
**Users and permissions**. Credentials are resolved on the first tool call, so a credential problem
is reported as a readable tool error instead of the server failing to launch. After the first
successful call the client, and its OAuth2 access token, is reused for the rest of the session, so
later calls skip the JWT signing and token exchange. A failed resolution is not cached, so fixing
the key file takes effect on the next call without a restart.

### Tools

Read tools are always advertised. Write tools appear only when `GOOGLE_PLAY_ENABLE_WRITES=1` —
an agent exploring release state should not be one malformed argument away from changing a
production rollout.

"Kind" is whether it reads or changes Play state. "Live-verified" is how far it has been
exercised against a real Play Console account (see [Verification status](#verification-status)).

On connect, the server also sends the host a short set of **instructions**: start with
`play_release_overview`, the 7-day review window, the Data safety limitation, and whether writes
are enabled. Most hosts fold these into the agent's context, so the agent does not have to learn
them by failing a call.

| Tool | Kind | Live-verified | What it answers |
|---|---|---|---|
| `play_release_overview` | read | built from verified reads | Tracks, rollout percentages, bundles, and APKs in one call (one edit) |
| `play_list_tracks` | read | yes | What is live on every track, and at what rollout percentage |
| `play_get_track` | read | yes | The same, for one track |
| `play_list_bundles` | read | yes | Which AABs have been uploaded |
| `play_list_apks` | read | yes | Which APKs have been uploaded |
| `play_list_reviews` | read | yes | Recent user reviews with rating, device, and app version |
| `play_validate_edit` | read | yes | Would the app's current state pass Play's pre-commit checks |
| `play_update_rollout` | write | encoding only | Change the staged-rollout fraction |
| `play_halt_rollout` | write | encoding only | Halt an in-progress rollout |
| `play_upload_and_release` | write | mocked only | Upload an AAB/APK and release it to a track |
| `play_upload_data_safety_labels` | write | mocked only | Upload a Safety Labels CSV |

#### Verification status

**built from verified reads**: `play_release_overview` makes the same `tracks`, `bundles`, and
`apks` requests as the list tools, just concurrently inside one edit. Rerun the live suite to
confirm it against your account.

**yes** — verified against a live Play Console account: authentication, tracks, bundles, APKs,
reviews, and a throwaway edit created and confirmed deleted.

**encoding only** — `play_update_rollout` and `play_halt_rollout` have their request encoding
verified live (a track `PUT` plus Play's pre-commit validation, inside an edit that is deleted
rather than committed), and their refusal path checked against a real track. Advancing or halting
a *real* staged rollout is still unproven — it needs an app with a live rollout to act on.

**mocked only** — `play_upload_and_release` end to end and `play_upload_data_safety_labels` are
proven only against mocked HTTP. Both need an app with a publishable artifact. Treat them
accordingly.

Run the live suite yourself — see [Live tests](#live-tests).

#### What the Play API cannot do

`applications.dataSafety` is **write-only**. There is no endpoint that reads back the current
published Data safety declaration, and none that distinguishes a published declaration from an
unpublished draft — verifying what is live has to happen in the Play Console UI. No MCP server
built on this API can answer that question.

Google also only returns reviews from roughly the last week.

### Run it

```bash
swift build -c release --product google-play-store-mcp
.build/release/google-play-store-mcp --help
```

### Register with a client

Supported clients: Claude Code, Codex CLI, Cursor, Windsurf.

```bash
scripts/install-mcp.sh --service-account-path /path/to/service-account.json
```

Registration is user-wide, available across projects (Claude Code uses `--scope user`).
The installer prefers `--binary`, then the executable on `PATH` (including Homebrew), then
a release/debug build in this checkout, regardless of the directory you run it from.

With no `--client` flag it detects whichever of those are installed and asks before touching
each one's config (Claude Code and Codex go through their own `mcp add` CLI; Cursor and Windsurf
get a JSON diff, confirmation, and a timestamped backup of the file it edits). Nothing runs
automatically as part of `brew install` — you run this by hand, whenever you want the server
registered. Add `--writes` to enable the write tools, `--package-name com.example.app` to set a
default package, `--dry-run` to preview without writing, or
`--client <name>` to target one client. See `scripts/install-mcp.sh --help` for all options.

To register by hand instead, the config shape is the same for every client except Codex (which
uses TOML in `~/.codex/config.toml` under `[mcp_servers.google-play-store]`):

```json
{
  "mcpServers": {
    "google-play-store": {
      "command": "/path/to/google-play-store-mcp",
      "env": {
        "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": "/path/to/service-account.json"
      }
    }
  }
}
```

Add `"GOOGLE_PLAY_ENABLE_WRITES": "1"` to that `env` block to enable the write tools.

| Client | Config file |
|---|---|
| Claude Code | `claude mcp add` (see `claude mcp add --help`) |
| Codex CLI | `codex mcp add` (see `codex mcp add --help`), or `~/.codex/config.toml` |
| Cursor | `~/.cursor/mcp.json` (or `.cursor/mcp.json` for one project) |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |

### Claude Code plugin and skills

This repo is also a Claude Code plugin marketplace. The `google-play-store` plugin registers the
MCP server and adds three skills that tell the agent how to combine the tools:

| Skill | Use it for |
|---|---|
| `play-release-check` | "What's live?": tracks, rollout percentages, newest artifact, and how the rolling version is reviewed |
| `play-rollout` | Advancing or halting a staged rollout: read, check reviews, confirm, act, verify |
| `play-review-triage` | Grouping the last week of reviews into themes by version and device |

```text
/plugin marketplace add ShipItSwifty/google-play-store-mcp
/plugin install google-play-store@shipitswifty-google-play
```

The plugin launches `google-play-store-mcp` from your `PATH` and passes through your shell
environment. Export `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH` (and `GOOGLE_PLAY_ENABLE_WRITES=1` if
you want the rollout skill to act) before starting Claude Code. If you already registered the
server with `install-mcp.sh`, you can keep that registration and use only the skills. Both are
named `google-play-store`, so you get one server either way.

The skills are plain `SKILL.md` files in
[`plugins/google-play-store/skills`](plugins/google-play-store/skills). Other agents that read the
same format (for example, Codex under `~/.codex/skills`) can use them as-is.

### Example prompts

- "What's live on every track for com.example.app?"
- "Is the 4.2.0 rollout healthy enough to go from 10% to 25%?" (read-only unless writes are enabled)
- "Summarize this week's 1- and 2-star reviews by theme and app version."
- "Which version codes are uploaded but not assigned to any track?"
- "Halt the production rollout." (needs `GOOGLE_PLAY_ENABLE_WRITES=1`; the agent should confirm first)

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No Google Play credentials found` | None of the credential variables reached the server process. With the plugin, export them in the shell that starts Claude Code. With `install-mcp.sh`, re-run it with `--service-account-path`. |
| `Could not read a Google service account key` | The file is not a service-account key. An OAuth client secret (`"installed"`/`"web"`) is a common mix-up. |
| `403 … PERMISSION_DENIED` | The service account is not invited in Play Console, lacks the permission for that app, or was invited recently and the grant has not propagated yet. |
| `404` on an app | Wrong `packageName`, or the app has never had a build uploaded in the Play Console. |
| `Tool '…' modifies Play Store state and is disabled` | Writes are off. Set `GOOGLE_PLAY_ENABLE_WRITES=1` in the server's `env`, or re-run the installer with `--writes`. |
| `userFraction must be greater than 0 and less than 1` | `1.0` is not a full rollout on Play. Use a `completed` release. |
| No reviews returned | Google only serves about the last 7 days. |
| Play Console shows a pending edit you did not make | Should not come from this server: every read deletes its edit, and failed writes delete theirs. Check for another tool holding an edit. Play also expires abandoned edits on its own. |

## Development

See [AGENTS.md](AGENTS.md) for the invariants any change must keep (edits never leak, one error
type, `Sendable` throughout, nothing shells out) and the checklist for adding an MCP tool.

```bash
swift build
swift test --enable-code-coverage --no-parallel
scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
```

### Smoke test

Drive the server over stdio (it should list read tools only):

```bash
swift build --product google-play-store-mcp
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 3
} | .build/debug/google-play-store-mcp
```

For interactive poking, the MCP Inspector works too:
`npx @modelcontextprotocol/inspector .build/debug/google-play-store-mcp`.

### Live tests

The default run is fully mocked. To check the client against a real Play Console account
(read-only — it creates and deletes throwaway edits, and publishes nothing):

```bash
GOOGLE_PLAY_TEST_PACKAGE_NAME=com.example.app \
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=./service-account.json \
  swift test --filter LiveGooglePlayTests
```

It skips when those are unset. Adding `GOOGLE_PLAY_LIVE_WRITE_TESTS=1` additionally exercises the
write encoding — a track `PUT` and Play's pre-commit validation, inside an edit that is deleted
rather than committed, so the app does not change. No test uploads an artifact or commits an edit.

### Coverage

`scripts/coverage-gate.sh` enforces a line-coverage floor over product code only. CI sets
`MIN_LINE_COVERAGE: "78"`; actual coverage is ~81%. Raise the floor as coverage climbs.

## Releasing

Tag with bare SemVer — no `v` prefix:

```bash
git tag 0.1.0 && git push origin 0.1.0
```

The release workflow stamps the version into `Entry.swift`, builds a macOS universal binary and a
static Linux binary, attests both, and publishes a GitHub release.

## License

MIT — see [LICENSE](LICENSE).
