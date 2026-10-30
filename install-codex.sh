#!/usr/bin/env bash
# Install only tmux team management. Agent-mail is owned by work/skills.
set -euo pipefail
TEAM_CODEX_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEAM_CODEX_NODE="$(command -v node)"
TEAM_CODEX_BIN="${TEAM_CODEX_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$TEAM_CODEX_BIN"
chmod +x "$TEAM_CODEX_REPO/codex-extension.mjs"
ln -sfn "$TEAM_CODEX_REPO/codex-extension.mjs" "$TEAM_CODEX_BIN/codex-team"
codex mcp add team -- "$TEAM_CODEX_NODE" "$TEAM_CODEX_REPO/codex-extension.mjs" --mcp
printf 'Installed team MCP and %s/codex-team. Reload MCP or resume Codex to discover tools.\n' "$TEAM_CODEX_BIN"
