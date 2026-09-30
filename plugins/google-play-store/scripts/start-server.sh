#!/bin/sh
# Install google-play-store-mcp before enabling the plugin; see README.md.
# Replace the launcher so stdio and termination belong to the MCP server.
exec google-play-store-mcp "$@"
