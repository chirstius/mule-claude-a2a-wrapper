#!/usr/bin/env bash
# End-to-end check of the Claude managed agent WITHOUT Mule (bash/curl/jq equivalent of smoke-test.ps1).
# Creates a session against the agent+environment from ids.json, sends a user.message, polls until the
# session goes idle, then prints the agent's text output, any files it produced, and token usage.
# Usage: ./smoke-test.sh [PROMPT] [TIMEOUT_SECONDS]   (key from env var or .env next to this script)
#   PROMPT           positional 1, or $PROMPT          (default: haiku-about-integration prompt)
#   TIMEOUT_SECONDS  positional 2, or $TIMEOUT_SECONDS  (default: 240)
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

[ -f .env ] && set -a && . ./.env && set +a
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY (env var or .env)}"

PROMPT="${1:-${PROMPT:-Create a file named hello.txt containing a short haiku about enterprise integration, then tell me what you wrote.}}"
TIMEOUT_SECONDS="${2:-${TIMEOUT_SECONDS:-240}}"

[ -f ids.json ] || { echo "ids.json not found. Run ./setup.sh first." >&2; exit 1; }
AGENT_ID=$(jq -r '.agent_id' ids.json)
ENVIRONMENT_ID=$(jq -r '.environment_id' ids.json)

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

echo "==> Creating session (agent $AGENT_ID)..."
SESSION_BODY=$(jq -n --arg a "$AGENT_ID" --arg e "$ENVIRONMENT_ID" '{agent:$a, environment_id:$e}')
SESSION_JSON=$(api POST /sessions "$SESSION_BODY")
SID=$(jq -r '.id' <<<"$SESSION_JSON")
echo "    session id: $SID"

echo "==> Sending prompt..."
echo "    \"$PROMPT\""
EVENT_BODY=$(jq -n --arg t "$PROMPT" \
  '{events:[{type:"user.message", content:[{type:"text", text:$t}]}]}')
api POST "/sessions/$SID/events" "$EVENT_BODY" >/dev/null

echo "==> Working (polling session status)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
SEEN_RUNNING=false
FINAL_JSON=""
while true; do
  sleep 3
  S=$(api GET "/sessions/$SID")
  STATUS=$(jq -r '.status' <<<"$S")
  echo "    status: $STATUS"
  [ "$STATUS" = "running" ] && SEEN_RUNNING=true
  if [ "$STATUS" = "failed" ] || [ "$STATUS" = "error" ]; then
    echo "Session ended with status '$STATUS'." >&2; exit 1
  fi
  if [ "$STATUS" = "idle" ] && [ "$SEEN_RUNNING" = true ]; then FINAL_JSON="$S"; break; fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo "Timed out after $TIMEOUT_SECONDS s (last status: $STATUS)." >&2; exit 1
  fi
done

echo
echo "==> Agent output:"
EVENTS=$(api GET "/sessions/$SID/events")
jq -r '.data[] | select(.type=="agent.message" and .content!=null) | .content[] | select(.type=="text") | .text' <<<"$EVENTS"

# Surface files the agent wrote (these become A2A artifacts in the wrapper).
WRITES=$(jq -r '.data[] | select(.type=="agent.tool_use" and (.name=="Write" or .name=="Edit" or .name=="MultiEdit")) | "    [" + .name + "] " + ((.input.file_path // .input.path) // "")' <<<"$EVENTS")
if [ -n "$WRITES" ]; then
  echo
  echo "==> Files the agent touched (future A2A artifacts):"
  echo "$WRITES"
fi

if [ "$(jq -r '.usage // empty' <<<"$FINAL_JSON")" != "" ]; then
  echo
  echo "==> Token usage:"
  echo "    input  : $(jq -r '.usage.input_tokens' <<<"$FINAL_JSON")"
  echo "    output : $(jq -r '.usage.output_tokens' <<<"$FINAL_JSON")"
  echo "    cache_read    : $(jq -r '.usage.cache_read_input_tokens' <<<"$FINAL_JSON")"
  echo "    cache_creation: $(jq -r '.usage.cache_creation_input_tokens' <<<"$FINAL_JSON")"
fi
echo
echo "Smoke test complete. Session $SID is idle and resumable."
