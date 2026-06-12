#!/usr/bin/env bash
# Multi-turn test: proves the wrapper reuses the same Claude session across two A2A
# message/send calls that share a contextId (exercises the contextId -> sessionId store).
# Turn 1 establishes a fact; Turn 2 (same contextId) checks the agent remembers it.
# Usage: ./multiturn-test.sh [BASE_URL] [AGENT_PATH]
#        BASE_URL   (default http://localhost:8081)  env: BASE_URL
#        AGENT_PATH (default /a2a)                    env: AGENT_PATH
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH" >&2; exit 1; }

BASE_URL="${1:-${BASE_URL:-http://localhost:8081}}"
AGENT_PATH="${2:-${AGENT_PATH:-/a2a}}"

send_a2a() { # send_a2a PROMPT [CONTEXT_ID]
  local prompt="$1" contextId="${2:-}"
  local body
  body=$(jq -n --arg prompt "$prompt" --arg ctx "$contextId" '
    {
      jsonrpc: "2.0",
      id: ("urn:uuid:" + (now | tostring)),
      method: "message/send",
      params: {
        message: (
          {
            role: "user",
            kind: "message",
            messageId: ("urn:uuid:" + (now | tostring)),
            parts: [ { kind: "text", text: $prompt } ]
          }
          + (if $ctx == "" then {} else { contextId: $ctx } end)
        )
      }
    }')
  curl -fsSL -X POST "$BASE_URL$AGENT_PATH" \
    -H "content-type: application/json" \
    -d "$body"
}

echo "==> Turn 1 (no contextId): establish a fact"
r1=$(send_a2a "My name is Chuck and my favorite color is teal. Acknowledge in one short sentence." "")
ctx1=$(jq -r '.result.contextId // empty' <<<"$r1")
echo "    contextId: $ctx1"
echo "    answer   : $(jq -r '.result.artifacts[0].parts[0].text // empty' <<<"$r1")"

echo
echo "==> Turn 2 (SAME contextId): test memory / session reuse"
r2=$(send_a2a "Without being told again, what is my name and favorite color?" "$ctx1")
ctx2=$(jq -r '.result.contextId // empty' <<<"$r2")
echo "    contextId: $ctx2"
echo "    answer   : $(jq -r '.result.artifacts[0].parts[0].text // empty' <<<"$r2")"

echo
echo "==> Verdict:"
if [ "$ctx2" = "$ctx1" ]; then
  echo "    [ok] contextId preserved across turns"
else
  echo "    [!] contextId changed ($ctx1 -> $ctx2) - mapping not via message.contextId"
fi
mem=$(jq -r '.result.artifacts[0].parts[0].text // empty' <<<"$r2")
if [[ "$mem" == *Chuck* && "$mem" == *teal* ]]; then
  echo "    [ok] agent recalled name + color -> Claude session was REUSED"
else
  echo "    [!] memory not confirmed - inspect the Turn 2 answer above"
fi
