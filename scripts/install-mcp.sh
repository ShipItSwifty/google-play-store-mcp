#!/usr/bin/env bash
# Registers google-play-store-mcp with an installed MCP client (Claude Code, Codex,
# Cursor, Windsurf). Run by hand — never invoked automatically by `brew install`.
#
# Usage:
#   scripts/install-mcp.sh [--client claude-code|codex|cursor|windsurf|all]
#                           [--binary /path/to/google-play-store-mcp]
#                           [--service-account-path /path/to/service-account.json]
#                           [--writes] [--yes] [--dry-run]
#
# With no --client, detects every supported client that appears to be installed
# and asks before touching each one's config.

set -euo pipefail

SERVER_NAME="google-play-store"
CLIENT="all"
BINARY=""
SERVICE_ACCOUNT_PATH=""
ENABLE_WRITES=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) CLIENT="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --service-account-path) SERVICE_ACCOUNT_PATH="$2"; shift 2 ;;
    --writes) ENABLE_WRITES=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$BINARY" ]]; then
  for candidate in .build/release/google-play-store-mcp .build/debug/google-play-store-mcp; do
    if [[ -x "$candidate" ]]; then
      BINARY="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      break
    fi
  done
fi

if [[ -z "$BINARY" ]]; then
  if command -v google-play-store-mcp >/dev/null 2>&1; then
    BINARY="$(command -v google-play-store-mcp)"
  else
    echo "error: no binary found. Build it first:" >&2
    echo "  swift build -c release --product google-play-store-mcp" >&2
    echo "or pass --binary /path/to/google-play-store-mcp" >&2
    exit 1
  fi
fi

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

json_merge() {
  # json_merge <config-file> <server-key> <command-json>
  local file="$1" key="$2" command_json="$3"
  local existing="{}"
  if [[ -f "$file" ]]; then
    existing="$(cat "$file")"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq --argjson entry "$command_json" --arg key "$key" \
      '.mcpServers[$key] = $entry' <<<"$existing"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$key" "$command_json" <<'PYEOF' <<<"$existing"
import json, sys
existing = json.load(sys.stdin)
key = sys.argv[1]
entry = json.loads(sys.argv[2])
existing.setdefault("mcpServers", {})[key] = entry
print(json.dumps(existing, indent=2))
PYEOF
  else
    echo "error: need jq or python3 to edit JSON config safely" >&2
    exit 1
  fi
}

write_json_config() {
  # write_json_config <label> <config-file>
  local label="$1" file="$2"
  local env_json="{}"
  if [[ -n "$SERVICE_ACCOUNT_PATH" ]]; then
    env_json="$(printf '{"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH": "%s"}' "$SERVICE_ACCOUNT_PATH")"
  fi
  if [[ "$ENABLE_WRITES" -eq 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      env_json="$(jq -c '. + {"GOOGLE_PLAY_ENABLE_WRITES": "1"}' <<<"$env_json")"
    else
      env_json="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['GOOGLE_PLAY_ENABLE_WRITES']='1'; print(json.dumps(d))" "$env_json")"
    fi
  fi
  local command_json
  command_json="$(printf '{"command": "%s", "env": %s}' "$BINARY" "$env_json")"

  local merged
  merged="$(json_merge "$file" "$SERVER_NAME" "$command_json")"

  echo "== $label =="
  echo "config file: $file"
  if [[ -f "$file" ]]; then
    echo "--- current mcpServers.$SERVER_NAME (if any) ---"
    if command -v jq >/dev/null 2>&1; then
      jq --arg key "$SERVER_NAME" '.mcpServers[$key] // "(none)"' "$file" 2>/dev/null || true
    fi
  else
    echo "(file does not exist yet, will be created)"
  fi
  echo "--- proposed mcpServers.$SERVER_NAME ---"
  echo "$command_json" | (command -v jq >/dev/null 2>&1 && jq . || cat)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(dry run — not writing)"
    return 0
  fi

  if ! confirm "Write this to $file?"; then
    echo "skipped $label"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    cp "$file" "$file.bak.$(date +%s)"
  fi
  printf '%s\n' "$merged" > "$file"
  echo "updated $file (backup saved alongside it if it existed before)"
}

install_claude_code() {
  if ! command -v claude >/dev/null 2>&1; then
    return 1
  fi
  echo "== Claude Code =="
  local args=(mcp add "$SERVER_NAME")
  if [[ -n "$SERVICE_ACCOUNT_PATH" ]]; then
    args+=(--env "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=$SERVICE_ACCOUNT_PATH")
  fi
  if [[ "$ENABLE_WRITES" -eq 1 ]]; then
    args+=(--env "GOOGLE_PLAY_ENABLE_WRITES=1")
  fi
  args+=(-- "$BINARY")
  echo "would run: claude ${args[*]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if confirm "Run this claude mcp add command?"; then
    claude "${args[@]}"
  else
    echo "skipped Claude Code"
  fi
}

install_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    return 1
  fi
  echo "== Codex CLI =="
  local args=(mcp add "$SERVER_NAME")
  if [[ -n "$SERVICE_ACCOUNT_PATH" ]]; then
    args+=(--env "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH=$SERVICE_ACCOUNT_PATH")
  fi
  if [[ "$ENABLE_WRITES" -eq 1 ]]; then
    args+=(--env "GOOGLE_PLAY_ENABLE_WRITES=1")
  fi
  args+=(-- "$BINARY")
  echo "would run: codex ${args[*]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if confirm "Run this codex mcp add command?"; then
    codex "${args[@]}"
  else
    echo "skipped Codex"
  fi
}

install_cursor() {
  if [[ ! -d "$HOME/.cursor" ]]; then
    return 1
  fi
  write_json_config "Cursor" "$HOME/.cursor/mcp.json"
}

install_windsurf() {
  if [[ ! -d "$HOME/.codeium/windsurf" ]]; then
    return 1
  fi
  write_json_config "Windsurf" "$HOME/.codeium/windsurf/mcp_config.json"
}

ran_any=0
run_if_selected() {
  local name="$1" fn="$2"
  if [[ "$CLIENT" != "all" && "$CLIENT" != "$name" ]]; then
    return
  fi
  if "$fn"; then
    ran_any=1
  elif [[ "$CLIENT" == "$name" ]]; then
    echo "error: $name does not appear to be installed" >&2
    exit 1
  fi
}

run_if_selected claude-code install_claude_code
run_if_selected codex install_codex
run_if_selected cursor install_cursor
run_if_selected windsurf install_windsurf

if [[ "$ran_any" -eq 0 ]]; then
  echo "No supported MCP clients detected (claude, codex, ~/.cursor, ~/.codeium/windsurf)."
  echo "See README.md for manual registration instructions."
fi
