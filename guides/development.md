# Development and releases

See [AGENTS.md](../AGENTS.md) for the invariants any change must keep (edits never leak, one error
type, `Sendable` throughout, nothing shells out) and the checklist for adding an MCP tool.

```bash
swift build
swift test --enable-code-coverage --no-parallel
scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
```

## Smoke test

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

## Live tests

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

## Coverage

`scripts/coverage-gate.sh` enforces a line-coverage floor over product code only. CI sets
`MIN_LINE_COVERAGE: "78"`; actual coverage is ~81%. Raise the floor as coverage climbs.

## Releasing

Tag with bare SemVer — no `v` prefix:

```bash
git tag 0.1.0 && git push origin 0.1.0
```

The release workflow stamps the version into `Entry.swift`, builds a macOS universal binary and a
static Linux binary, attests both, and publishes a GitHub release.
