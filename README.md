# google-play-store-mcp

Swift clients for Google service-account authentication and the Google Play Developer API, plus an
MCP server for Play release state. The libraries run on macOS and Linux; the server is read-only by
default.

| Product | Purpose |
|---|---|
| `GoogleAuthKit` | Service-account JWT and OAuth2 exchange, plus Workload Identity Federation for Google APIs. |
| `GooglePlayKit` | Play Developer API client for tracks, rollouts, artifacts, reviews, and releases. |
| `google-play-store-mcp` | MCP server exposing Play reads and optional release writes. |

## Quick start

1. [Create a service account with Play Console access](guides/server-setup.md#service-account-setup).
2. Build and register the server:

   ```bash
   swift build -c release --product google-play-store-mcp
   scripts/install-mcp.sh --service-account-path /path/to/service-account.json
   ```

3. Ask your agent: “What's live on production for `com.example.app`, and how are reviews for the new version?”

Write tools appear only when `GOOGLE_PLAY_ENABLE_WRITES=1`. See the [tool catalog](guides/tools.md#tool-catalog)
for what the server can do and how each tool has been verified.

## Guides

| Guide | Contents |
|---|---|
| [Libraries](guides/library.md) | SwiftPM installation, API examples, edit lifecycle, errors, and test setup. |
| [Server setup](guides/server-setup.md) | Service account permissions, credentials, client registration, plugin, and troubleshooting. |
| [MCP tools](guides/tools.md) | Tool catalog, live verification status, Play API limits, and example prompts. |
| [Development and releases](guides/development.md) | Build, tests, coverage, smoke test, and release workflow. |

## License

MIT — see [LICENSE](LICENSE).
