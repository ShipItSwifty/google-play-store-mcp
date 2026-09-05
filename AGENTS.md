# google-play-store-mcp — Agent Guidance

Single source of truth for AI agents working in this repository (Claude Code, OpenAI Codex, etc.).

## What this is

Three products in one package:

- **`GoogleAuthKit`** — Google service-account credentials, RS256 JWT → OAuth2 exchange, and
  GitHub Actions Workload Identity Federation. Scope-agnostic; also backs Firebase callers.
- **`GooglePlayKit`** — Google Play Developer API v3 client, DTOs, and the release workflow.
  Depends on `GoogleAuthKit`.
- **`google-play-store-mcp`** — MCP server over stdio, read-only unless `GOOGLE_PLAY_ENABLE_WRITES=1`.

Extracted from [ShipItSwifty](https://github.com/ShipItSwifty/shipitswifty), which consumes
`GoogleAuthKit` + `GooglePlayKit` and maps `GoogleAPIError` onto its own `ShipItError`.

## Read first on a cold start

- `Package.swift`
- `Sources/GooglePlayKit/GooglePlayReadAPI.swift` — the edit lifecycle, and the most subtle code here
- `Sources/GooglePlayMCPServer/Tools/PlayTools.swift` — the tool catalog and the write gate
- `Tests/GooglePlayKitTests/GooglePlayReadAPITests.swift`

## Hard invariants

1. **Reads never commit an edit.** Every edit-scoped read goes through
   `withReadOnlyEdit(packageName:_:)`, which deletes the edit on both the success and failure path.
   A leaked edit shows in the Play Console as a pending change and blocks a human from starting
   their own, so this is a correctness requirement, not tidiness.
2. **Writes clean up after themselves.** A failed `uploadAndRelease` deletes its edit before
   rethrowing; cleanup errors are discarded so they cannot mask the real failure.
3. **One error type.** Everything throws `GoogleAPIError`. Never introduce a second error enum —
   downstream consumers bridge exactly one.
4. **All public types are `Sendable`**, Swift 6 strict concurrency throughout.
5. **Nothing shells out.** No `Foundation.Process`, no SwiftyShell. This keeps both libraries
   Linux-clean.
6. **`userFraction` rides only with a staged status, and is exclusive.** Play accepts it on
   `.inProgress` *and* `.halted`, and requires `0 < userFraction < 1` — a full rollout is a
   `.completed` release, not `1.0`. `assignToTrack` strips it on `.completed`/`.draft`;
   `haltRollout` preserves it so the pause point survives.

## Adding an MCP tool

1. Add a `ToolSpec` to `PlayTools.readSpecs` or `PlayTools.writeSpecs` in
   `Sources/GooglePlayMCPServer/Tools/PlayTools.swift`. The JSON Schema is derived from the
   `arguments` array, so there is no separate schema to update and no dispatch `switch` to extend.
2. Set `isReadOnly: false` for anything that changes Play state — that both gates it behind
   `GOOGLE_PLAY_ENABLE_WRITES` and sets the `destructiveHint` the host shows the user.
3. Back it with a method on `GooglePlayClient` (in `GooglePlayReadAPI.swift`) rather than
   assembling requests in the tool handler.
4. Add tests in `Tests/GooglePlayMCPServerTests/PlayToolsTests.swift`. The catalog tests
   (uniqueness, gating, required arguments) cover new tools automatically.
5. Update the tool table in `README.md`.

## API limitations worth knowing before promising anything

- **Data safety is write-only.** `applications.dataSafety` accepts a Safety Labels CSV and returns
  an empty body. There is no read endpoint, and no published-vs-draft distinction. Verifying a Data
  safety declaration must happen in the Play Console UI.
- **Reviews are ~7 days.** `reviews.list` will not return older reviews, however you page it.
- **Most reads need an edit.** See invariant 1.

## Commands

```bash
swift build
swift test --enable-code-coverage --no-parallel
scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests

# MCP smoke test — should list read tools only.
swift build --product google-play-store-mcp
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 3
} | .build/debug/google-play-store-mcp
```

## Vetting a release against a real account

Everything in the default test run uses mocked HTTP, which proves request shapes and the edit
lifecycle but not that Google accepts them. `Tests/GooglePlayKitTests/LiveIntegrationTests.swift`
closes that gap and is the intended pre-tag check. It is **read-only** — the only writes are the
throwaway edits Play requires for reads, each of which is deleted.

```bash
GOOGLE_PLAY_TEST_PACKAGE_NAME=com.example.app \
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=./service-account.json \
  swift test --filter LiveGooglePlayTests
```

Without both variables the suite skips with a message naming what is missing, so CI stays green
without credentials. Run it before tagging.

Adding `GOOGLE_PLAY_LIVE_WRITE_TESTS=1` enables two more tests that exercise the write encoding
against Play — a track PUT and Play's own pre-commit validation — inside an edit that is then
deleted rather than committed, so the app does not change. Still uncovered live: `uploadAndRelease`
end to end, and a real staged rollout being advanced or halted, both of which need a throwaway app
with an artifact to publish.

## Conventions

- Tags and versions are **bare SemVer, no `v` prefix** (`0.1.0`, not `v0.1.0`).
- No `CHANGELOG.md` — GitHub Releases carry per-tag notes.
- Bump `GooglePlayMCPVersion.current` only via the release workflow, which stamps it from the tag.
