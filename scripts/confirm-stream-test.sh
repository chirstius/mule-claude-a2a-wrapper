#!/usr/bin/env bash
# End-to-end STREAMING tool-confirmation (input-required) round-trip against the deployed wrapper.
# Requires the wrapper pointed at the CONFIRM agent with confirmation.default = defer.
#
#   Turn 1: message/stream a prompt that uses a tool. The SSE stream relays 'working' updates and then
#           ENDS on a final 'input-required' status carrying a tool-confirmation-request DataPart. (The
#           stream closing here is by design - we do NOT hold a connection open across the think-time.)
#   Turn 2: message/stream again on the SAME contextId with a tool-confirmation-response DataPart; the
#           stream resumes and ends on 'completed' with the answer artifact.
#   Uses curl -N. Each turn's stream is finite (it closes on the final status), so we collect the
#   lines, print them, and parse the 'data:' frames to drive the next turn.
#
# Usage: confirm-stream-test.sh [URL] [PROMPT] [DECISION allow|deny] [DENY_MESSAGE] [DELAY_SECONDS]
#   or via env vars: URL, PROMPT, DECISION, DENY_MESSAGE, DELAY_SECONDS
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH." >&2; exit 1; }

URL="${1:-${URL:-http://localhost:8081/a2a}}"
PROMPT="${2:-${PROMPT:-Create a file named stream-approval.txt with a short haiku about gates, then tell me what you wrote.}}"
DECISION="${3:-${DECISION:-allow}}"
DENY_MESSAGE="${4:-${DENY_MESSAGE:-Policy: do not write that file; just tell me the haiku.}}"
DELAY_SECONDS="${5:-${DELAY_SECONDS:-0}}"

case "$DECISION" in
  allow|deny) ;;
  *) echo "DECISION must be 'allow' or 'deny' (got '$DECISION')." >&2; exit 1 ;;
esac

# ANSI colors
C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_RESET=$'\033[0m'

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null | tr 'A-Z' 'a-z'; }

# Invoke-Stream <ctx> <parts-json> <label> -> prints the SSE lines and emits them on stdout.
# Returns the raw response lines (one per line) so the caller can capture them.
invoke_stream() {
  local ctx="$1" parts="$2" label="$3"
  local body tmp lines
  body=$(jq -cn --arg id "$(uuid)" --arg msgId "$(uuid)" --arg ctx "$ctx" --argjson parts "$parts" \
    '{jsonrpc:"2.0", id:$id, method:"message/stream",
      params:{message:{role:"user", kind:"message", messageId:$msgId, contextId:$ctx, parts:$parts}}}')
  tmp=$(mktemp)
  printf '%s' "$body" > "$tmp"
  printf '\n%s---- [%s] SSE stream ----%s\n' "$C_CYAN" "$label" "$C_RESET" >&2
  lines=$(curl -N -s -S -X POST "$URL" \
    -H "content-type: application/json" \
    -H "accept: text/event-stream" \
    --data "@$tmp") || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  # Echo each line (dark gray) to stderr so it doesn't pollute the captured stdout.
  while IFS= read -r l; do
    printf '%s    %s%s\n' "$C_GRAY" "$l" "$C_RESET" >&2
  done <<< "$lines"
  printf '%s' "$lines"
}

# Parse all 'data:' frames and UNWRAP the JSON-RPC envelope to its .result (the A2A object).
# Emits one compact JSON object (the .result) per line.
get_frames() {
  local lines="$1"
  while IFS= read -r l; do
    case "$l" in
      data:*)
        local j="${l#data:}"
        # trim leading/trailing whitespace
        j="$(printf '%s' "$j" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$j" ] && continue
        printf '%s' "$j" | jq -ce 'select(.result != null) | .result' 2>/dev/null || true
        ;;
    esac
  done <<< "$lines"
}

ctx="ctx-stream-confirm-$(uuid)"
printf '%s==> contextId: %s%s\n' "$C_GRAY" "$ctx" "$C_RESET"

# ---- Turn 1 ----
parts1=$(jq -cn --arg t "$PROMPT" '[{kind:"text", text:$t}]')
lines1=$(invoke_stream "$ctx" "$parts1" "turn 1: prompt")
frames1=$(get_frames "$lines1")

# Find the tool-confirmation-request DataPart anywhere in the streamed frames.
# Emits the .data of the matching part.
reqData=$(printf '%s\n' "$frames1" | jq -cs '
  [ .[]
    | (.status.message.parts // [])[]
    | select(.kind == "data" and .data.type == "tool-confirmation-request")
    | .data
  ] | first // empty')

if [ -z "$reqData" ]; then
  printf '%sWARNING: No input-required / tool-confirmation-request frame seen. Is the wrapper on the confirm agent with confirmation.default=defer?%s\n' "$C_YELLOW" "$C_RESET" >&2
  exit 0
fi

# pending tool calls
printf '\n%s==> pending tool calls:%s\n' "$C_CYAN" "$C_RESET"
printf '%s' "$reqData" | jq -r '
  .calls[]
  | "      - " + .toolUseId + "  [" + .name + "]"
    + (if .input.file_path then " -> " + .input.file_path else "" end)'

if [ "$DELAY_SECONDS" -gt 0 ]; then
  printf '\n%s==> Simulating caller think-time: waiting %s s before answering%s\n' "$C_YELLOW" "$DELAY_SECONDS" "$C_RESET"
  printf '%s    (turn-1 stream is already CLOSED; the Claude session waits at requires_action)%s\n' "$C_GRAY" "$C_RESET"
  sleep "$DELAY_SECONDS"
fi

# ---- Turn 2: answer on the SAME contextId ----
decisions=$(printf '%s' "$reqData" | jq -c --arg decision "$DECISION" --arg deny "$DENY_MESSAGE" '
  [ .calls[]
    | { toolUseId: .toolUseId, result: $decision }
      + (if $decision == "deny" then { denyMessage: $deny } else {} end)
  ]')

parts2=$(jq -cn --argjson decisions "$decisions" '
  [ {kind:"text", text:"Here is my decision."},
    {kind:"data", data:{type:"tool-confirmation-response", decisions:$decisions}} ]')

lines2=$(invoke_stream "$ctx" "$parts2" "turn 2: $DECISION -> resume")
frames2=$(get_frames "$lines2")

completed=$(printf '%s\n' "$frames2" | jq -cs '[ .[] | select(.status.state == "completed") ] | first // empty')
artifactText=$(printf '%s\n' "$frames2" | jq -rs '
  ([ .[] | select(.artifact != null) ] | first) as $a
  | ($a.artifact.parts // [])[]
  | select(.kind == "text")
  | .text')

printf '\n%s==> Result:%s\n' "$C_CYAN" "$C_RESET"
if [ -n "$artifactText" ]; then
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done <<< "$artifactText"
fi
if [ -n "$completed" ]; then terminal="True"; else terminal="False"; fi
printf '%s    terminal state seen: %s%s\n' "$C_GREEN" "$terminal" "$C_RESET"
printf '\n%sStreaming confirmation round-trip complete.%s\n' "$C_GREEN" "$C_RESET"
