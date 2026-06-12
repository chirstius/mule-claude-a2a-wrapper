#!/usr/bin/env bash
# Archives the agent and archives+deletes the environment created by setup.sh (bash/curl/jq equivalent of teardown.ps1).
# Archiving makes resources read-only (existing sessions keep running). Environment delete only
# succeeds if no sessions still reference it. Removes ids.json / .env.local on success.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./teardown.sh   (or put the key in .env next to this script)
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

[ -f .env ] && set -a && . ./.env && set +a
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY (env var or .env)}"

[ -f ids.json ] || { echo "ids.json not found — nothing to tear down." >&2; exit 1; }
AGENT_ID=$(jq -r '.agent_id' ids.json)
ENVIRONMENT_ID=$(jq -r '.environment_id' ids.json)

try_call() { # try_call METHOD PATH
  local method="$1" path="$2"
  if curl -fsSL -X "$method" "https://api.anthropic.com/v1$path" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: managed-agents-2026-04-01" \
      -H "content-type: application/json" >/dev/null 2>&1; then
    echo "    ok: $method $path"
  else
    echo "    $method $path -> request failed" >&2
  fi
}

echo "==> Archiving agent $AGENT_ID..."
try_call POST "/agents/$AGENT_ID/archive"

echo "==> Archiving environment $ENVIRONMENT_ID..."
try_call POST "/environments/$ENVIRONMENT_ID/archive"

echo "==> Deleting environment $ENVIRONMENT_ID..."
try_call DELETE "/environments/$ENVIRONMENT_ID"

rm -f ids.json .env.local
echo
echo "Teardown done (ids.json / .env.local removed)."
