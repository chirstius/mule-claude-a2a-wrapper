#!/usr/bin/env bash
# End-to-end test of the A2A tool-confirmation (input-required) HITL round-trip against the
# deployed Mule wrapper (bash/curl/jq equivalent of confirm-test.ps1). Requires the wrapper
# pointed at the CONFIRM agent (agent-confirm) with confirmation.default = defer (so a tool
# call surfaces as input-required).
#   1) message/send with a prompt that uses a tool -> expect a Task in state 'input-required'
#      carrying a tool-confirmation-request DataPart (calls[] with toolUseId/name/input).
#   2) message/send again on the SAME contextId with a tool-confirmation-response DataPart
#      (allow or deny each toolUseId) -> expect a 'completed' Task with the answer (allow) or
#      the agent working around the denial (deny).
#
# Usage: ./confirm-test.sh [BaseUrl] [AgentPath] [Prompt] [Decision allow|deny] [DenyMessage] [DelaySeconds]
#   or via env vars: BASE_URL, AGENT_PATH, PROMPT, DECISION, DENY_MESSAGE, DELAY_SECONDS
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH." >&2; exit 1; }

BASE_URL="${1:-${BASE_URL:-http://localhost:8081}}"
AGENT_PATH="${2:-${AGENT_PATH:-/a2a}}"
PROMPT="${3:-${PROMPT:-Create a file named approval-demo.txt containing a short haiku about gatekeeping, then tell me what you wrote.}}"
DECISION="${4:-${DECISION:-allow}}"
DENY_MESSAGE="${5:-${DENY_MESSAGE:-Policy: not allowed to write that file. Just tell me the haiku instead.}}"
DELAY_SECONDS="${6:-${DELAY_SECONDS:-0}}"

case "$DECISION" in
  allow|deny) ;;
  *) echo "Decision must be 'allow' or 'deny' (got '$DECISION')." >&2; exit 1 ;;
esac

# send_message CTX PARTS_JSON -> raw JSON-RPC response on stdout
send_message() {
  local ctx="$1" parts="$2" body
  body=$(jq -n --arg ctx "$ctx" --argjson parts "$parts" \
    --arg rid "$(uuidgen)" --arg mid "$(uuidgen)" '
    {
      jsonrpc: "2.0",
      id: $rid,
      method: "message/send",
      params: {
        message: {
          role: "user",
          kind: "message",
          messageId: $mid,
          contextId: $ctx,
          parts: $parts
        }
      }
    }')
  curl -sS -X POST "$BASE_URL$AGENT_PATH" \
    -H "content-type: application/json" \
    -d "$body"
}

ctx="ctx-confirm-$(uuidgen)"
echo "==> contextId: $ctx"

# ---- Turn 1: prompt that triggers a gated tool ----
echo
echo "==> [1] message/send (prompt that uses a tool)..."
parts1=$(jq -n --arg text "$PROMPT" '[ { kind: "text", text: $text } ]')
r1=$(send_message "$ctx" "$parts1")

state1=$(jq -r '.result.status.state // empty' <<<"$r1")
echo "    state: $state1"
if [ "$state1" != "input-required" ]; then
  echo "Expected 'input-required'. Is the wrapper pointed at the confirm agent with confirmation.default=defer?" >&2
  echo "Full response:"
  jq '.' <<<"$r1"
  exit 0
fi

# Extract the tool-confirmation-request DataPart.
reqPart=$(jq -c 'first(.result.status.message.parts[]? | select(.kind == "data" and .data.type == "tool-confirmation-request")) // empty' <<<"$r1")
if [ -z "$reqPart" ]; then
  echo "No tool-confirmation-request DataPart found." >&2
  jq '.' <<<"$r1"
  exit 0
fi
calls=$(jq -c '.data.calls // []' <<<"$reqPart")

echo "    pending tool calls:"
jq -r '.[] | "      - " + .toolUseId + "  [" + .name + "]" + (if .input.file_path then " -> " + .input.file_path else "" end)' <<<"$calls"

if [ "$DELAY_SECONDS" -gt 0 ]; then
  echo
  echo "==> Simulating caller think-time: waiting $DELAY_SECONDS s before answering"
  sleep "$DELAY_SECONDS"
fi

# ---- Turn 2: answer with a tool-confirmation-response on the SAME contextId ----
echo
echo "==> [2] message/send (tool-confirmation-response = $DECISION) on same contextId..."
decisions=$(jq -c --arg decision "$DECISION" --arg deny "$DENY_MESSAGE" '
  [ .[] | { toolUseId: .toolUseId, result: $decision }
          + (if $decision == "deny" then { denyMessage: $deny } else {} end) ]' <<<"$calls")

# A small text part too (callers usually attach one); the wrapper keys off the DataPart.
parts2=$(jq -n --argjson decisions "$decisions" '
  [ { kind: "text", text: "Here is my decision." },
    { kind: "data", data: { type: "tool-confirmation-response", decisions: $decisions } } ]')

r2=$(send_message "$ctx" "$parts2")

state2=$(jq -r '.result.status.state // empty' <<<"$r2")
echo "    state: $state2"
echo
echo "==> Final answer / artifacts:"
if [ "$(jq -r '(.result.artifacts // []) | length' <<<"$r2")" != "0" ]; then
  jq -r '.result.artifacts[] | "  [" + .name + "]", (.parts[]? | select(.kind == "text") | "    " + .text)' <<<"$r2"
else
  echo "  (no artifacts) full response:"
  jq '.' <<<"$r2"
fi
echo
echo "Confirmation round-trip complete."
