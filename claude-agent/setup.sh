#!/usr/bin/env bash
# Creates the Claude managed agent + cloud environment (bash/curl/jq equivalent of setup.ps1).
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./setup.sh   (or put the key in .env next to this script)
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] && set -a && . ./.env && set +a
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY (env var or .env)}"
MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-5}"

api() { # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsSL -X "$method" "https://api.anthropic.com/v1$path" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: managed-agents-2026-04-01" \
      -H "content-type: application/json" \
      -d "$body"
  else
    curl -fsSL -X "$method" "https://api.anthropic.com/v1$path" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: managed-agents-2026-04-01"
  fi
}

echo "==> Creating cloud environment..."
ENV_JSON=$(api POST /environments "$(cat environment.json)")
ENVIRONMENT_ID=$(jq -r '.id' <<<"$ENV_JSON")
echo "    environment id : $ENVIRONMENT_ID"

echo "==> Creating managed agent (model: $MODEL)..."
AGENT_BODY=$(jq --arg m "$MODEL" '.model=$m' agent.json)
AGENT_JSON=$(api POST /agents "$AGENT_BODY")
AGENT_ID=$(jq -r '.id' <<<"$AGENT_JSON")
AGENT_VERSION=$(jq -r '.version' <<<"$AGENT_JSON")
echo "    agent id       : $AGENT_ID"
echo "    agent version  : $AGENT_VERSION"

jq -n --arg a "$AGENT_ID" --argjson v "$AGENT_VERSION" --arg e "$ENVIRONMENT_ID" --arg m "$MODEL" \
  '{agent_id:$a, agent_version:$v, environment_id:$e, model:$m}' > ids.json

cat > .env.local <<EOF
ANTHROPIC_AGENT_ID=$AGENT_ID
ANTHROPIC_AGENT_VERSION=$AGENT_VERSION
ANTHROPIC_ENVIRONMENT_ID=$ENVIRONMENT_ID
EOF

echo
echo "Saved ids.json and .env.local."
echo "Next: create a session and send a user.message to test (see smoke-test.ps1 for the flow)."
