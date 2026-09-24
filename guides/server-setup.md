# Set up the MCP server

## Service account setup

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

> The MCP server reads a JSON key. `GoogleAuthKit`'s keyless `WorkloadIdentityFederationClient`
> currently issues `cloud-platform`-scoped tokens, which the Play Developer API does not accept,
> so it is not yet an alternative for Play.

## Credentials

Read from the environment, in priority order:

| Variable | Meaning |
|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Raw service account key JSON |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH` | Path to the key file |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to the key file (Google-wide convention) |

The service account needs Play Developer API access to the app, granted in the Play Console under
**Users and permissions**. Credentials are resolved on the first tool call, so a credential problem
is reported as a readable tool error instead of the server failing to launch. After the first
successful call the client, and its OAuth2 access token, is reused for the rest of the session, so
later calls skip the JWT signing and token exchange. A failed resolution is not cached, so fixing
the key file takes effect on the next call without a restart.

## Run it

```bash
swift build -c release --product google-play-store-mcp
.build/release/google-play-store-mcp --help
```

## Register with a client

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
registered. Add `--writes` to enable the write tools, `--dry-run` to preview without writing, or
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

## Claude Code plugin and skills

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
[`plugins/google-play-store/skills`](../plugins/google-play-store/skills). Other agents that read the
same format (for example, Codex under `~/.codex/skills`) can use them as-is.

## Troubleshooting

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
