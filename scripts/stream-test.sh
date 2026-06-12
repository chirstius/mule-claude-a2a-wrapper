#!/usr/bin/env bash
# Drives the streaming path: POSTs an A2A message/stream and prints the raw SSE events as
# they arrive (status-update / artifact-update). Uses a prompt that triggers a tool call so
# you can watch the per-tool relay ("Using tool(s): write -> /...") show up live.
# Uses curl -N (no buffering) because a buffered client would hold the whole response.
#
# Usage: ./stream-test.sh [URL] [PROMPT]
#   URL     base A2A endpoint (default http://localhost:8081/a2a; or env URL)
#   PROMPT  message text (default a haiku-writing prompt; or env PROMPT)
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH" >&2; exit 1; }

URL="${1:-${URL:-http://localhost:8081/a2a}}"
PROMPT="${2:-${PROMPT:-Create a file named haiku.txt containing a haiku about streaming data, then briefly tell me what you wrote.}}"

# Build the request body with jq (handles JSON escaping cleanly).
body=$(jq -n --arg mid "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)" --arg prompt "$PROMPT" '{
  jsonrpc: "2.0",
  id: "stream-1",
  method: "message/stream",
  params: {
    message: {
      role: "user",
      kind: "message",
      messageId: $mid,
      parts: [ { kind: "text", text: $prompt } ]
    }
  }
}')

# BOM-less UTF-8 temp file so curl sends clean JSON.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$body" > "$tmp"

echo "POST message/stream -> $URL"
echo "prompt: $PROMPT"
echo "---- SSE stream (events arrive as the agent works) ----"
curl -N -s -S -X POST "$URL" \
  -H "content-type: application/json" \
  -H "accept: text/event-stream" \
  --data "@$tmp"
echo
echo "---- stream closed ----"
