#!/usr/bin/env bash
# Exercises the deployed Mule wrapper locally: fetches the agent card, then sends an A2A
# JSON-RPC message/send. Run AFTER the app is deployed (with -M-Dclaude.apiKey set for the
# message/send to actually reach Claude). bash/curl/jq equivalent of local-test.ps1.
# Usage: ./local-test.sh [BASE_URL] [AGENT_PATH] [PROMPT]
#   BASE_URL   (or $BASE_URL)   default http://localhost:8081
#   AGENT_PATH (or $AGENT_PATH) default /a2a
#   PROMPT     (or $PROMPT)     default "In one sentence, what is the A2A protocol?"
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

BASE_URL="${1:-${BASE_URL:-http://localhost:8081}}"
AGENT_PATH="${2:-${AGENT_PATH:-/a2a}}"
PROMPT="${3:-${PROMPT:-In one sentence, what is the A2A protocol?}}"

echo "==> GET agent card (no secret needed)..."
for cardUrl in "$BASE_URL/.well-known/agent-card.json" "$BASE_URL$AGENT_PATH/.well-known/agent-card.json"; do
  if card=$(curl -fsSL -X GET "$cardUrl" 2>/dev/null); then
    echo "    [200] $cardUrl"
    echo "    name: $(jq -r '.name' <<<"$card")  protocol: $(jq -r '.protocolVersion' <<<"$card")  streaming: $(jq -r '.capabilities.streaming' <<<"$card")"
    break
  else
    echo "    [miss] $cardUrl"
  fi
done

echo
echo "==> POST message/send (JSON-RPC) to $BASE_URL$AGENT_PATH ..."
# Generate a UUID (prefer uuidgen, fall back to /proc, then a jq-based fallback).
if command -v uuidgen >/dev/null 2>&1; then
  messageId=$(uuidgen | tr '[:upper:]' '[:lower:]')
elif [ -r /proc/sys/kernel/random/uuid ]; then
  messageId=$(cat /proc/sys/kernel/random/uuid)
else
  messageId=$(jq -rn -- '
    def h: [range(0;16)]|map("0123456789abcdef"[(now*1000000+.|floor)%16:1])|add;
    (h+h)[0:8]+"-"+(h)[0:4]+"-4"+(h)[0:3]+"-"+(["8","9","a","b"][(now*100|floor)%4])+(h)[0:3]+"-"+(h+h)[0:12]')
fi

body=$(jq -n --arg id "$messageId" --arg prompt "$PROMPT" '
  {
    jsonrpc: "2.0",
    id: "test-1",
    method: "message/send",
    params: {
      message: {
        role: "user",
        kind: "message",
        messageId: $id,
        parts: [ { kind: "text", text: $prompt } ]
      }
    }
  }')

if resp=$(curl -fsSL -X POST "$BASE_URL$AGENT_PATH" \
    -H "content-type: application/json" \
    -d "$body" 2>/tmp/local-test-err); then
  echo "    raw response:"
  jq '.' <<<"$resp"
else
  status=$?
  echo "HTTP error (curl exit $status): $(cat /tmp/local-test-err)" >&2
  rm -f /tmp/local-test-err
fi
rm -f /tmp/local-test-err 2>/dev/null || true
