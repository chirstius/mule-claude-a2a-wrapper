#!/usr/bin/env bash
# Empirically test what the A2A connector does to our running flow on tasks/cancel.
# Starts a long streaming turn, captures the taskId from the first SSE event, waits, then sends a
# JSON-RPC tasks/cancel for that task. Observes whether the stream stops early / reports 'canceled'
# (=> the connector interrupts our flow, so we can wire claude-interrupt) or runs on to 'completed'
# (=> no flow hook; clean cancel not supported by this connector version). Also dumps the cancel
# response and the runtime-log delta so we can see if the flow was actually interrupted.
#
# Usage: ./cancel-probe.sh [URL] [RUNTIME_LOG] [CANCEL_AFTER_SECONDS] [OBSERVE_SECONDS]
#   or via env: URL=... RUNTIME_LOG=... CANCEL_AFTER_SECONDS=... OBSERVE_SECONDS=... ./cancel-probe.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not found on PATH" >&2; exit 1; }

URL="${1:-${URL:-http://localhost:8081/a2a}}"
RuntimeLog="${2:-${RUNTIME_LOG:-D:\\mule-ee\\mule-enterprise-standalone-4.11.4\\logs\\mule_ee.log}}"
CancelAfterSeconds="${3:-${CANCEL_AFTER_SECONDS:-6}}"
ObserveSeconds="${4:-${OBSERVE_SECONDS:-25}}"

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python - <<'PY' 2>/dev/null || od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
import uuid; print(uuid.uuid4())
PY
  fi
}

ctx="ctx-cancel-$(gen_uuid)"
prompt="Write a thorough, detailed technical essay of at least 1500 words about enterprise integration patterns, event-driven architecture, idempotency, and the saga pattern. Take your time and be comprehensive."

req=$(jq -nc --arg id "$(gen_uuid)" --arg mid "$(gen_uuid)" --arg ctx "$ctx" --arg prompt "$prompt" \
  '{jsonrpc:"2.0", id:$id, method:"message/stream", params:{message:{role:"user", kind:"message", messageId:$mid, contextId:$ctx, parts:[{kind:"text", text:$prompt}]}}}')

reqFile="$(mktemp)"
streamFile="$(mktemp)"
printf '%s' "$req" > "$reqFile"

if [ -f "$RuntimeLog" ]; then logStart=$(wc -l < "$RuntimeLog"); else logStart=0; fi

echo "==> starting streaming turn (ctx=$ctx)..."
curl -N -s -X POST "$URL" \
  -H "content-type: application/json" \
  -H "accept: text/event-stream" \
  --data "@$reqFile" > "$streamFile" &
curlPid=$!

curl_alive() { kill -0 "$curlPid" 2>/dev/null; }

taskId=""
for ((i=0; i<50 && -z "$taskId"; i++)); do
  sleep 0.4
  c="$(cat "$streamFile" 2>/dev/null || true)"
  if [ -n "$c" ]; then
    m="$(printf '%s' "$c" | grep -oE '"result"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' | head -n1 | grep -oE '[0-9a-fA-F-]{36}' | head -n1 || true)"
    if [ -n "$m" ]; then taskId="$m"; fi
    if [ -z "$taskId" ]; then
      m="$(printf '%s' "$c" | grep -oE '"taskId"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' | head -n1 | grep -oE '[0-9a-fA-F-]{36}' | head -n1 || true)"
      if [ -n "$m" ]; then taskId="$m"; fi
    fi
  fi
  [ -n "$taskId" ] && break
done

if [ -z "$taskId" ]; then
  echo "WARNING: never saw a taskId; stream so far:" >&2
  cat "$streamFile" || true
  curl_alive && kill "$curlPid" 2>/dev/null || true
  exit 0
fi
echo "    taskId = $taskId"

sleep "$CancelAfterSeconds"
eventsBefore=$(grep -cE "^event:" "$streamFile" 2>/dev/null || echo 0)
if curl_alive; then exited="False"; else exited="True"; fi
echo "==> sending tasks/cancel after ${CancelAfterSeconds}s (SSE events so far: $eventsBefore, stream exited: $exited)..."

cancelReq=$(jq -nc --arg id "$(gen_uuid)" --arg tid "$taskId" \
  '{jsonrpc:"2.0", id:$id, method:"tasks/cancel", params:{id:$tid}}')

if cancelResp="$(curl -fsS -X POST "$URL" -H "content-type: application/json" --data "$cancelReq")"; then
  echo "    cancel response: $(printf '%s' "$cancelResp" | jq -c . 2>/dev/null || printf '%s' "$cancelResp")"
else
  echo "WARNING: cancel call error" >&2
fi

sleep "$ObserveSeconds"
curl_alive && kill "$curlPid" 2>/dev/null || true

eventsAfter=$(grep -cE "^event:" "$streamFile" 2>/dev/null || echo 0)
states="$(grep -oE '"state":"[a-z-]+"' "$streamFile" 2>/dev/null | grep -oE ':"[a-z-]+"' | tr -d ':"' | paste -sd' ' - | sed 's/ / -> /g')"

echo
echo "==> RESULT"
echo "    SSE events before cancel: $eventsBefore ; total after observation: $eventsAfter"
echo "    task states seen in stream: $states"
echo "    stream tail:"
tail -n 5 "$streamFile" 2>/dev/null | while IFS= read -r line; do
  [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] && echo "      $line"
done

echo
echo "    runtime log delta (flow behavior):"
if [ -f "$RuntimeLog" ]; then
  tail -n +$((logStart + 1)) "$RuntimeLog" 2>/dev/null \
    | grep -E "claude-run-turn|Created Claude session|cancel|interrupt|ERROR|tool_use|agent.message|status_idle" \
    | tail -n 12 | while IFS= read -r line; do echo "      $line"; done
fi

rm -f "$reqFile" "$streamFile" 2>/dev/null || true

echo
echo "==> INTERPRETATION:"
echo "    If states end at 'canceled' and/or events stopped right after cancel => connector INTERRUPTS the flow (cancel is wireable)."
echo "    If states reach 'completed' with an answer artifact => flow ran to completion despite cancel (no hook)."
