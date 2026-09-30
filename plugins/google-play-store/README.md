# Google Play Store by ShipItSwifty

Inspect your Android app's Google Play releases and recent reviews from Claude, and optionally
advance or halt a staged rollout. This independent MIT-licensed plugin is maintained by
ShipItSwifty and is not affiliated with or endorsed by Google.

## What it includes

| Skill | Workflow |
|---|---|
| `play-release-check` | Report tracks, rollout percentages, uploaded artifacts, and recent reviews. |
| `play-review-triage` | Group the last week's reviews by theme, app version, and device. |
| `play-rollout` | Read state, check reviews, confirm the requested change, act, and verify. |

The plugin starts a local `google-play-store-mcp` server over stdio. Its launcher runs the
executable already installed on your `PATH`; it does not download, install, or build software.
Install the server before enabling the plugin.

## Install and configure in Claude Code

On macOS, install the server:

```sh
brew install shipitswifty/tap/google-play-store-mcp
google-play-store-mcp --version
```

For Linux or a source build, follow the repository's
[server setup guide](https://github.com/ShipItSwifty/google-play-store-mcp/blob/main/guides/server-setup.md).
Make sure the executable is on the `PATH` of the process that starts Claude Code.

Install the plugin from Claude Code:

```text
/plugin marketplace add ShipItSwifty/google-play-store-mcp
/plugin install google-play-store@shipitswifty-google-play
```

When enabling the plugin, select a Google service account JSON key with Play Console access.
The [service account setup instructions](https://github.com/ShipItSwifty/google-play-store-mcp/blob/main/guides/server-setup.md#service-account-setup)
explain the API and app permissions. You can also set a default Android package. Release writes
are off by default; enable them explicitly in the plugin configuration when you need them.
The plugin supplies its configured credentials and write setting to the server rather than
using credentials inherited from your shell. Standalone server registration still supports
the environment variables documented in the setup guide.

Try: “What's live on production for `com.example.app`, and what do the recent reviews say?”

## Claude surfaces

Claude Code loads the local server and prompts for configuration. Claude chat loads the skills
but ignores local MCP servers, so this plugin alone cannot access Play data there. Local Cowork
supports local servers, but currently skips servers whose required user configuration has no
default; this plugin requires a service account file. The configured tools currently target
Claude Code. A hosted connector would be needed for Play access in chat.

## Data and actions

The server reads the selected key file locally, signs a JWT, and exchanges it with Google's token
endpoint (normally `https://oauth2.googleapis.com/token`). It sends authenticated requests to
`https://androidpublisher.googleapis.com` and returns results to your Claude session. Credentials
contain the token endpoint, so use a trusted Google-issued key. The server keeps the authenticated
client and access token in process memory; it does not create a database or persist review data.
Claude's handling of conversation content follows your Claude account's settings and policies.

Review results can contain reviewer names and review text. Reads of release state create and
delete temporary Play edits without committing them. Enabled write tools can upload a build
from a local file, publish a release, change or halt a rollout, or submit a Data safety CSV.
The rollout skill asks for confirmation before changing Play state.

Reviews cover roughly seven days. Crash and ANR data are unavailable through these tools, and
Data safety declarations cannot be read back. See the
[tool catalog](https://github.com/ShipItSwifty/google-play-store-mcp/blob/main/guides/tools.md)
for the current tools and limitations.

## License and support

MIT — see [LICENSE](LICENSE). Report problems in
[GitHub issues](https://github.com/ShipItSwifty/google-play-store-mcp/issues).
