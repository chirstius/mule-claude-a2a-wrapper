# Design — Claude Managed Agent ⟷ A2A Wrapper

## 1. Goal & principles

Expose an Anthropic **Claude Managed Agent** as a compliant **A2A server** via a MuleSoft application,
so any A2A client or orchestrator can discover it and delegate tasks to it.

Non-negotiables:

- **Lean & portable.** A single, config-driven Mule app. No dependency on any other project. Standing up
  a new instance = set `claude.*` + drop in an `agent-card.json`.
- **Pure protocol adapter.** No business logic, no PII/governance filtering, no custom-tool execution.
  Those belong to the caller or a fronting gateway.
- **Protocol-faithful.** Where A2A defines a mechanism (e.g. `input-required` for human/agent-in-the-loop),
  use it rather than inventing an out-of-band path.

## 2. Why A2A (not MCP)

Managed Claude agents are long-running, stateful, autonomous task executors: *create session → send events
→ agent works in a sandbox → goes idle*. That maps almost 1:1 onto A2A's **Task lifecycle**
(submitted → working → input-required → completed). MCP models *tool calls*; A2A models *delegating a task
to another agent and tracking it to completion* — which is exactly what a session is.

## 3. Topology

```
A2A client ──A2A/HTTP──▶ Mule wrapper (A2A Connector = SERVER) ──HTTPS/SSE──▶ Claude Managed Agents API
```

The MuleSoft A2A Connector provides the server scaffolding (agent-card endpoint, JSON-RPC routing, task
repository object store, Task/Task-Stream listeners, SSE broadcast ops). We supply the adapter logic.

## 4. Core mapping (A2A ⟷ Claude sessions)

| A2A (front) | Claude Managed Agents (back) |
|---|---|
| **Agent Card** (skills, capabilities) | Hand-authored discovery doc. Claude has no card concept; we author it. |
| **`contextId`** (conversation grouping) | **Session ID** — the persistent, stateful conversation. Stored. |
| **`taskId`** (a unit of work) | One turn: `user.message` → run until `session.status_idle`. |
| **`message/send`** (blocking) | create-or-resume session → run to `status_idle(end_turn)` → return artifact + `completed`. |
| **`message/stream`** (SSE) | open `events/stream`, then send `user.message`; relay events; `end_turn` completes. |
| task `working` | session `running` |
| task **`input-required`** | `status_idle` + `stop_reason: requires_action` (tool confirmation) |
| task `completed` | `status_idle` + `stop_reason: end_turn` |
| task `failed` | `session.error` event |
| **`tasks/cancel`** | `user.interrupt` event |
| **push notification config** | on `status_idle`, connector's Send Push Notification |
| **Artifact** | files written by the agent (from file-write tool-use events) + terminal text |

## 5. State model (the keystone)

Two stores (swappable: in-memory for demo, Object Store for prod):

1. **`contextId → sessionId`** — conversation continuity.
   - New/absent `contextId` → `POST /v1/sessions` (agent + environment), persist mapping, send first `user.message`.
   - Known `contextId` → look up `sessionId`, send another `user.message` (Claude resumes from checkpoint).
2. **`taskId → { sessionId, pendingToolUseIds[] }`** — correlates a confirmation answer back to the exact
   blocking events. (Task status itself rides the connector's built-in task repository.)

> **Checkpoint TTL:** Claude checkpoints persist 30 days after last activity. If sandbox state must outlive
> that, an optional keep-alive `user.message` resets the timer (`claude.sessionKeepAliveDays`).

## 6. Entry points (both supported)

Both `message/send` (blocking) and `message/stream` (SSE) funnel into the same create-or-resume +
confirmation sub-flows — the adapter logic is written once.

- **Blocking:** create/resume → send → await `status_idle` → write durable artifact + `completed`.
- **Streaming:** open Claude SSE first (avoid the race), send, relay each event as an A2A `working` status
  update (tool-call breadcrumbs + partial text), then finalize.

### 6.1 The blocking poll loop (why, and how it exits)

**Why poll at all.** The Managed Agents API is asynchronous: sending a `user.message` only *queues*
work and returns immediately; the agent then runs for seconds, emitting events. A blocking A2A
`message/send` must return the final answer in the HTTP response, so the wrapper has to wait for the
turn to finish. With an async backend, "wait" = poll. (Streaming would consume the SSE stream instead;
deferred.)

**Why not poll `session.status == idle`.** A freshly created session is *already* `idle` before any
message is processed, so a status poll exits instantly and reads an empty turn (`text:""`, zero usage).
The status field can't distinguish "idle, not started" from "idle, finished".

**Exit signal = a new end-of-turn marker.** Every completed turn appends exactly one `session.status_idle`
event carrying a `stop_reason`. So we **baseline the count** of those markers *before* sending
(`priorIdle`), then poll the event list until the count exceeds the baseline — i.e. a *new* marker
appeared. Counting (not "exists") is what makes it correct across multi-turn (turn 2 already has turn 1's
marker).

**Loop mechanism.** Mule has no `while`, so we invert `until-successful`: its body fetches events and
**raises `APP:TURN_NOT_DONE` when *not* done**, which triggers a retry after the interval; when a new
marker appears, no error is raised and the scope "succeeds" and exits. The successful iteration's last
step is the events fetch, so `payload` is already the terminal event list feeding the result transform —
no extra call, and one poll yields both the done-signal and the content (hence polling events, not status).

**Bounds & config.** `maxRetries` × `intervalMs` (props `claude.poll.*`, default 100 × 3000ms ≈ 5 min) is
the budget; exhausting it throws → the error-handler returns a `failed` Task (no infinite hang).

**Connection hold (researched).** There is **no server-side timeout** that could cut us off: the A2A
connector exposes none, and the HTTP listener holds the connection open for the entire flow (its only
timeout, `readTimeout`/30s, governs *receiving* the request, not processing). So raising the poll budget
never makes the wrapper close early. The `retries × interval` figure matters for the hop *in front of us*
— configure the Flex Gateway / load balancer / caller read timeout to
`(maxRetries × intervalMs) + a2a.server.callerTimeoutBufferMs`. Callers may still time out; that's their
choice, but the wrapper won't be the one to end it prematurely.

## 7. Event relay & the durable-terminal-answer rule

The single most important correctness rule, learned by counter-example from the reference impl
(`ericabouaf/claude-a2a`), which buries the final answer in a transient `working` update:

> **The terminal answer MUST land in durable task state — a final `artifact` and/or the `completed`
> status `message` — never only in a streamed `working` update.**

Otherwise a blocking `message/send` client or a `tasks/get` poller loses the answer. Streamed working
updates are *additive*; the durable result is *mandatory*.

Relay loop (per Claude event):

| Claude event | A2A action |
|---|---|
| `agent.message` (text) | `working` status update (if streaming) **and** accumulate for the durable result |
| `agent.tool_use` / `agent.mcp_tool_use` | `working` breadcrumb: "Calling tool X" |
| file-write tool_use (detect by `input.file_path` presence) | `artifact-update` (one per file, last touch wins) |
| `session.status_idle` (`stop_reason.type == end_turn`) | finalize: durable artifact + `completed` status |
| `session.status_idle` (`stop_reason.type == requires_action`) | confirmation handling (§8) |
| `session.error` | `failed` status |

### Verified event taxonomy (from the live smoke test)

Real event sequence for a one-tool task (managed agent, prebuilt toolset):
`session.status_running` → `session.thread_status_running` → `user.message` →
`span.model_request_start` → `agent.thinking` → `agent.tool_use` → `span.model_request_end` →
`agent.tool_result` → `agent.message` → `session.thread_status_idle` → `session.status_idle`.

Confirmed shapes (do **not** assume Claude Code SDK names — they differ):
- **`agent.tool_use`**: `{ id, name, input, evaluated_permission, type }`. For file writes `name` is
  lowercase (e.g. `"write"`) and `input = { file_path, content }`. **Detect artifacts by `input.file_path`
  presence, not by tool name.** `evaluated_permission` (`"allow"` here) is the permission policy's
  decision — the signal the confirmation resolver (§8) reads.
- **`agent.message`**: `{ id, content: [ { type: "text", text } ], type }`.
- **`session.status_idle`**: carries `stop_reason: { type }` (`end_turn` here). A per-thread
  `session.thread_status_idle` mirrors it.
- Blocking poll confirmed: `GET /v1/sessions/{id}` returns `status` transitioning `running → idle`.

## 8. Tool-confirmation policy (HITL, protocol-native)

The wrapped agent only pauses for tools whose Managed-Agents **permission policy** requires confirmation.
The toolset policy is set at **agent-create** time (there are exactly two policy types — `always_allow`
and `always_ask`):

```json
"tools": [ { "type": "agent_toolset_20260401",
             "default_config": { "permission_policy": { "type": "always_ask" } },
             "configs": [ { "name": "bash", "permission_policy": { "type": "always_ask" } } ] } ]
```

`default_config` sets the toolset default (omitted ⇒ `always_allow`, which never pauses); `configs[]`
overrides individual tools. MCP toolsets default to `always_ask`. Our test backend `agent-confirm.json`
gates the whole toolset with `always_ask` (see §10). For each gated call the wrapper resolves a disposition:

```
deny-list match  -> deny      (deny wins ties; fail-safe)
allow-list match -> allow
otherwise        -> default   (defer | allow | deny)
```

- **`defer`** → emit A2A `input-required`; the caller decides. Protocol-native HITL — the wrapper is
  agnostic to *how* the caller surfaces it (human, another agent, auto-policy).
- **`allow`** → `user.tool_confirmation: allow`.
- **`deny`** → `user.tool_confirmation: deny` (+ `denyMessage`, which the agent sees and can adapt to).

Operator shortcuts: `default: allow` = "allow all" (no per-tool listing); `default: deny` = locked agent.

A session at `requires_action` is **idle and checkpointed → zero token cost while it waits**, so deferral
is also the cheap path.

### The `input-required` round-trip (DataPart convention) — as built

Standard A2A `DataPart`s (`kind: "data"`) keep the contract self-describing. The discriminator is a
`type` field inside the part's `data` object.

Pause → `input-required` status message carries a text part (human-readable) **and** a data part:
```json
{ "kind": "data",
  "data": { "type": "tool-confirmation-request", "taskId": "…",
            "calls": [ { "toolUseId": "sevt_…", "name": "write", "toolType": "agent.tool_use",
                         "key": "tool_use:write", "input": { "file_path": "…", "content": "…" } } ] } }
```
Caller continues (new message, **same `contextId`**) with:
```json
{ "kind": "data",
  "data": { "type": "tool-confirmation-response",
            "decisions": [ { "toolUseId": "sevt_…", "result": "allow" },
                           { "toolUseId": "sevt_…", "result": "deny", "denyMessage": "…" } ] } }
```
Each decision → `user.tool_confirmation { tool_use_id, result, deny_message? }`; the session resumes.

**How `requires_action` surfaces (verified, §13):** a gated tool emits `agent.tool_use` (carrying its own
event `id`), then `session.status_idle` with `stop_reason: { type: "requires_action", event_ids: [<that
id>] }`. The `tool_use_id` you confirm IS that event id. Multiple `event_ids` can block at once — resolve
each. The session's *top-level* `stop_reason` is empty; it lives on the **event**, which is exactly what
the SSE consumer reads.

**Inline auto-resolve (the elegant part):** because the wrapper is already attached to the session's live
SSE stream, `allow`/`deny` dispositions are POSTed *mid-consume* and the resumed events flow back down the
**same open stream** — no re-open, no second turn. Only `defer` breaks out to `input-required`.

> **Correlation is keyed by `contextId`, not `taskId`.** `contextId` is what an A2A client echoes to
> continue a conversation and what already drives Claude session continuity (`contextToSession`), so it
> survives even if the connector mints a fresh `taskId` on the continuation. Pending state
> (`{ sessionId, contextId, pending[] }`) lives in the `taskState` object store, written on pause and
> cleared on completion. **Fallback** (no decision DataPart on a continuation): per
> `confirmation.malformedResponse` — `denyAll`.

## 9. Input handling, cancellation, errors

- **Multi-part input:** map *all* incoming A2A message parts → `user.message` content blocks (text +
  any images). Do not drop non-text parts (the reference impl reads only the first text part).
- **Cancellation:** `tasks/cancel` → `user.interrupt`.
- **Errors:** `session.error` → task `failed` with the error message; never leave a task hanging.
- **Usage/cost:** read the session `usage` field at the terminal boundary for cost governance.

## 10. The backend agent (testable target)

Defined declaratively in `../claude-agent`:

- **Environment** (`environment.json`): `type: cloud`, `networking: unrestricted` for the POC. Production
  guidance: `limited` networking with an explicit `allowed_hosts` list (least privilege).
- **Agent** (`agent.json`): a general-purpose agent on the pre-built toolset (`agent_toolset_20260401`),
  which can read/write files, run shell, and search the web — so it produces artifacts.
- **Permission policy:** `agent.json`'s toolset is gated **`always_ask`** (`default_config.permission_policy`),
  so every server-executed tool pauses at `requires_action` and surfaces to the wrapper. The wrapper's
  `confirmation.{allow,deny,default}` then routes per tool — a single agent exercises **all three paths**:
  with the demo policy `read` → auto-allow (runs), `write` → `defer` → `input-required` (HITL), `bash` →
  auto-deny. (Historically a separate `always_allow` base agent + an `always_ask` confirm variant were
  used; these were merged into one `always_ask` agent — the wrapper now provides the per-tool mix, which
  is the differentiator. The agent was updated in place via `POST /agents/{id}` with the prior `version`.)

Scripts: `setup.ps1`/`setup.sh` create the environment + agent and save IDs; `smoke-test.ps1` creates a
session, sends a prompt, polls to idle, and prints the reply + artifacts + usage; `teardown.ps1` cleans up.

## 11. What this wrapper does beyond the reference impl (`ericabouaf/claude-a2a`)

That project is a useful reference but targets a **different backend** — the local **Claude Code SDK**
(tools run in the host's working directory), not the hosted Managed Agents API. Consequences and contrasts:

| Area | Reference impl | This wrapper |
|---|---|---|
| Backend | Claude Code SDK (local cwd) | Managed Agents API (isolated cloud sandbox) |
| Tool gating / `input-required` | none (observes via PostToolUse hook; tools always run) | defer/allow/deny resolver + `input-required` round-trip |
| Cancellation | no-op stub | `user.interrupt` |
| Error → `failed` | not mapped | mapped |
| Multi-part input | first text part only | all parts → content blocks |
| Terminal answer | in a transient `working` update (pollers lose it) | durable artifact + `completed` |
| Persistence / auth | in-memory map, auth commented out | swappable Object Stores, gateway-fronted auth |
| Push notifications | off | supported (blocking path) |

Validated by the reference (we kept these): `contextId → session` mapping, card-from-config, streaming as
a sequence of `working` status updates, artifacts derived from file-write events.

## 12. Build order

1. ✅ Backend definitions + setup/smoke-test scripts
2. ✅ Agent card + configuration contract
3. ✅ Mule: create-or-resume sub-flow (+ `contextId → sessionId` store)
4. ✅ Mule: blocking `message/send` — create→send→poll-to-end-of-turn→A2A Task (validated in Studio)
5. ✅ Mule: streaming `message/stream` relay (card `streaming`, `task-stream-listener`, per-tool-use relay)
6. ✅ Mule: confirmation resolver + `input-required` round-trip (§8) — HITL, single-approve resume
7. ✅ Mule: `tasks/cancel` → interrupt, `failed` mapping; ⚠️ push notifications partial (see docs/PUSH-NOTIFICATIONS.md)
8. ✅ End-to-end validated through a real A2A broker / multi-agent orchestrator

## 13. Validation results (Anypoint Studio, connector resolved at deploy)

Confirmed by deploying and driving the app locally:

- **Non-streaming response contract.** The `task-listener` flow returns its final `payload` as the
  JSON-RPC `result`, and it **must be a valid A2A Task**:
  `{ id, contextId, kind:"task", status:{state}, artifacts:[{artifactId, name, parts:[{kind:"text",text}]}] }`.
  The agent's answer goes in an artifact (not a top-level `message`). The connector enriches the Task with
  `status.timestamp` and `history:[]`. `update-task-status`/`update-task-artifact` are **streaming-only**.
- **Agent card** is served at **`{agentPath}/.well-known/agent-card.json`** (e.g. `/a2a/.well-known/...`),
  not at domain root. `<a2a:agent-card file="${app.home}/agent-card.json"/>` resolves correctly.
- **Multi-turn continuity validated.** The client's `contextId` arrives at **`payload.message.contextId`**
  (NOT top-level `payload.contextId`, which is null on inbound). Reusing it across `message/send` calls
  makes the wrapper resolve the same Claude session from the store — confirmed: the agent recalled facts
  from turn 1 in turn 2. The connector assigns the task id at `payload.id`.
- **Card ↔ listener consistency is enforced at deploy.** If the card advertises `streaming:true` you must
  have a `<a2a:task-stream-listener>` (same likely holds for `pushNotifications`). We set both `false`
  until those flows exist.
- **End-of-turn detection (race fix).** A freshly created session is already `idle`, so polling
  `GET /sessions/{id}.status == idle` returns immediately and reads an empty turn. Instead, **poll the
  event list until a *new* `session.status_idle` with a `stop_reason` appears** (baseline the count
  before sending). This also disambiguates multi-turn.
- **Mule/DataWeave gotchas** hit along the way (now in the user-global `CLAUDE.md`): quote reserved words
  (`type`,`input`) as DW identifiers; always declare `output` and coerce payload-derived values at
  extraction; YAML config values must be quoted strings and **must not be empty lists**; `<http:body>`
  before `<http:headers>`; `<when>` needs a body; `os:retrieve` null default throws `OS:KEY_NOT_FOUND`
  (use a sentinel).

### Streaming (`message/stream`) — validated, with its own quirks

The `a2a-message-stream` flow **consumes Claude's live SSE event stream** (`GET /sessions/{id}/events/stream`)
in real time — **no polling** — and relays each event over A2A SSE via
`update-task-status` / `update-task-artifact`. Sequence delivered to the client:
`submitted` (connector auto) → `working` (accepted) → per-tool `working` relay → `artifact-update` (answer)
→ `completed` (final). Hard-won specifics:

- **Stream listener exposes data differently than the blocking listener.** `payload` is just
  `{ message: {...} }`; the connector's **task id / context id live on `attributes.taskId` /
  `attributes.contextId`** (plus `attributes.jsonRpcMethod`). Using `payload.id` → a generated uuid →
  `update-task-status` fails with **`Task not found`**. Always use `attributes.taskId`.
- **`status-content` / `artifact-content` must be JSON**, not a Java object. Use
  `#[output application/json --- {…}]`; a bare `#[{…}]` serializes as Java bytes and the connector throws
  *"Unexpected character ('¬')"* unmarshalling into `io.a2a.spec.*`. (The doc example's `#[{…}]` is wrong.)
- **Strict A2A spec types** (`io.a2a.spec.TaskStatusUpdateEvent`, `…ArtifactUpdateEvent`, `Message`):
  the event uses **`taskId`** (not `id`); `status.message` is a real **Message** (`kind:"message"`, `role`,
  `parts:[{kind:"text",…}]`) with a **non-null `messageId`** (`uuid()`) — not `{kind:"text"}`.
- **Real SSE-attach — the unlock (no poll, no cursor).** The flow reads Claude's `/events/stream` and drives
  a `foreach` over it, so each event is seen exactly once — no Object Store cursor, no `until-successful`. The
  recipe is precise and every part is load-bearing (full version in global `CLAUDE.md`): `streamResponse="true"`
  on the request-connection (deferred response, no buffering); **send the user message BEFORE opening the
  stream** — an idle session emits nothing until a turn runs, so opening first deadlocks the requester waiting
  for the first byte; a DataWeave `payload as Iterator` transform right after the request makes `foreach`
  lazy (a raw `foreach` over the response throws `PrematureCloseException`); open *immediately* before the
  `foreach` or Mule closes the non-repeatable buffer ("Trying to write in a closed buffer"); break the loop
  with `raise-error APP:STREAM_DONE` caught by `on-error-continue logException="false"`. Confirmed 7/7
  deterministic. **This same consume engine can back the blocking path too** — same stream, just aggregate the
  events into the final Task instead of relaying (retiring the blocking poll loop and unifying both paths).
- A flow that errors mid-stream makes the connector **auto-emit a `failed` final status** (graceful close),
  so the client always gets a terminal event even if our error path is broken — but keep the error emit
  dead-simple so it can't throw.

### Unified turn engine (blocking + streaming on one SSE consume)

Both paths now call one shared sub-flow **`claude-run-turn`** (resolve-or-create session → send → consume
Claude's live SSE), parameterized by `vars.streamMode`:
- **streaming** (`streamMode=true`): relays each `agent.tool_use` as an interim `update-task-status`.
- **blocking** (`streamMode=false`): just aggregates — leaves `vars.finalText` + `vars.fileArtifacts`, and the
  flow builds the A2A Task from them.

The engine outputs `vars.finalText` (answer) and `vars.fileArtifacts` (`[{path,content}]`). The blocking poll
loop, the `claude-list-events` / `claude-get-session` sub-flows, and the `claude.poll.*` config have been
**removed**. Verified: blocking + multi-turn + streaming all green on the unified engine.

> **DataWeave-in-attribute gotcha:** `value="#[…]"` on `set-variable` cannot contain `<`, so the array-append
> `<<` operator breaks there — use `++ [ {…} ]` (or move the expression into a CDATA `<ee:set-payload>`).

## Open items

- **SSE connection lingers briefly after the turn (measured benign; log-suppressed).** When the `foreach`
  breaks at `end_turn` we stop reading Claude's `/events/stream` without explicitly closing it. ~8s later a
  keep-alive byte hits the abandoned buffer → one reactor `onErrorDropped` ("Trying to write in a closed
  buffer"); the connection survives that and **self-closes ~30–60s later** — confirmed by watching ESTABLISHED
  connections to Anthropic rise by one after a call and return to baseline within ~60s. So it is a **bounded,
  self-draining** connection, **not a leak** (≈ calls-in-the-last-60s extra conns under load, continuously
  draining). The log noise is suppressed cosmetically via `src/main/resources/log4j2.xml` (RegexFilter).
  Ruled out as fixes: `connectionIdleTimeout` (N/A — not idle), `usePersistentConnections=false` (kept on the
  dedicated `Anthropic_SSE_config` — helps it close on the sooner side, doesn't stop the line). A
  **deterministic instant-close** would need an explicit stream cancel (fragile in Mule) or a custom
  SSE-consumer connector that owns the connection — an **optional efficiency optimization, not a correctness
  or resource blocker.**
- **Confirmation / `input-required` — VALIDATED end-to-end (2026-06-04).** Resolver (`confirmation.xml`),
  `requires_action` handling in `claude-run-turn`, and the A2A round-trip in both entry flows. Tested against
  `agent-confirm.json` (`always_ask`): regression (base agent, blocking+stream+multiturn), inline auto-resolve
  (`default: allow` — the gated tool ran, proving Claude delivers post-confirmation events down the **same**
  open SSE stream), and the HITL `input-required` round-trip (blocking allow+deny, streaming allow, immediate
  **and** 60 s-delayed). The agent even adapts to a denial. The one-time empirical unknown (same-stream resume)
  is confirmed working — no re-open fallback needed.
- **`tasks/cancel` → `user.interrupt` — IMPLEMENTED + validated (2026-06-04, on the headless loop).**
  The connector requires an **`<a2a:authorization-listener>`** to process privileged verbs (a raw cancel
  rejects with JSON-RPC `-32005 "Authorization listener required for tasks/cancel"`). `a2a-authorize.xml`
  adds it: the listener exposes the request on `attributes` (`jsonRpcMethod`, `taskId`, `contextId`),
  **completing the flow = allow** (raising an error would deny). On `tasks/cancel` it resolves
  `taskId → sessionId` via the new **`taskToSession`** object store (written by `claude-run-turn` at turn
  start, since cancel carries only the `taskId`, no `contextId`) and calls `claude-interrupt` (`user.interrupt`).
  Verified: cancel returns `canceled`, the Claude session receives `user.interrupt` and stops, and the
  in-flight `claude-run-turn` unwinds (idle break hardened to fire on any terminal `session.status_idle`, so
  an interrupt can't leave the SSE consume hanging). Probe: `cancel-probe.ps1`. (Refinement TODO: the stream
  flow still emits its answer artifact/`completed` after a cancel — the connector no-ops it on a canceled
  task, so benign, but it could short-circuit on a detected cancel.)
- **Push notifications** (webhook leg) — PARTIALLY DONE; one integration gap remains (2026-06-04, on the loop).
  Added `<a2a:push-notification-config-listener>` (`a2a-push.xml`) + card `capabilities.pushNotifications: true`.
  Confirmed empirically: the listener **fires and accepts** a client's config (`payload.configuration.
  pushNotificationConfig.url`; `attributes.taskId/contextId`), and the **connector owns delivery** — it POSTs
  the terminal Task to the webhook itself (`Mule HTTP Client`; log `ServerAgent: Push notification sent
  successfully`), so no manual `http:request` is needed. A `message/send` with a config returns `submitted`
  immediately (correct async/fire-and-forget).
  **The gap:** when `message/send` carries an inline `configuration.pushNotificationConfig` AND a
  push-config-listener is registered, the connector dispatches the request to the **push-config-listener
  only** — the **task-listener never runs**, so the message isn't processed (no answer, no delivery). A plain
  `message/send` (no config) processes fine, so it's specific to the inline-config dispatch. The listener
  class has two callbacks (`onConfigAccepted`, `onPushNotification`) and a response future
  (`onSuccess` → `AcceptedPushNotificationConfigParameterGroup`: `additionalHeaders`/`authentication`/`proxy`/
  `timeout`). **Next:** (a) try having the listener flow *return* an `accepted-push-notification-config`
  response (the source's onSuccess) — the connector may gate message processing on a proper accept; and/or
  (b) use the dedicated `tasks/pushNotificationConfig/set` on a streaming task instead of inline config; and/or
  (c) get the connector's example/docs for the intended pattern. Test harness: `webhook-receiver.py`.
- **Usage/cost capture** — currently dropped from the response; re-add as governance metadata or a log.
- **Model ID** in `agent.json` defaults to `claude-sonnet-4-5`; confirm per workspace.
- **Auth on the A2A edge** (Flex Gateway / client credentials) — out of the wrapper, into the platform.
  - Related: the agent card's `url` is intentionally the **internal origin** (e.g. `http://localhost:8081/a2a`),
    not the public address. The **Flex Gateway A2A policy rewrites the card** — remapping `url` to the
    gateway-exposed endpoint — so the wrapper stays environment-agnostic and does not manage a public URL.
    Don't "fix" the localhost url in `agent-card.json`; the gateway owns that remap.
- **HITL robustness knobs — SPECCED, NOT WIRED (backlog).** Two config keys were removed from
  `common.yaml` during the config cleanup because no flow consumed them; the *behaviors* still need
  implementing, then re-add the keys:
  - `confirmation.deferTimeoutMinutes` — auto-deny a task left in `input-required` past a window
    (so a never-answered deferred task can't pin a Claude session open indefinitely). Needs a
    timed sweep over the `taskState` store (or a per-task scheduler) that injects a `deny` for
    pending tool-use ids on expiry.
  - `confirmation.malformedResponse` (`denyAll` | `treatAsNewMessage`) — what to do when a caller's
    continuation on a paused context lacks a `tool-confirmation-response` DataPart. Today the entry
    flows treat a missing response as a fresh turn implicitly; this key would make the fallback
    explicit/configurable (deny the pending calls vs. forward the text as a new instruction).
  Also note (intentionally left at fixed behavior, no config key): working-update relay is always-on
  in the streaming flow, and there is no session keep-alive pinger.

## Roadmap — Mule Agent Fabric integration

This wrapper is the **A2A on-ramp** that makes a Claude managed agent addressable as a first-class node in a
**Mule Agent Fabric agent network under a broker**. The end-state demo:

- Wrap **1–2 Claude managed agents** (each its own A2A server instance — same wrapper, different
  `claude.agentId`/`environmentId`, replicated by config) so they're reachable over A2A.
- Register them, **alongside a 2nd/3rd agent from another ecosystem**, into a Mule Agent Fabric **agent
  network** fronted by a **broker**.
- **Orchestrate across all of them by hitting the broker** — the broker does discovery/routing/composition;
  the engagement surface never talks to an individual agent directly.

**Engagement surfaces** (hit the broker, TBD per use case): a purpose-built **UI**, a **Slack** integration,
and potentially a **Claude** integration (Claude reaching the fabric as a client). Use cases TBD.

**Why the wrapper must stay lean & standards-pure:** it's one interchangeable node in a larger fabric.
Keeping it config-driven (point at a different agent/environment to replicate), protocol-native (A2A states
incl. `input-required` HITL — no bespoke control channel), and dependency-free is what lets the broker treat
Claude agents identically to any other A2A agent. Near-term steps toward this: finish the A2A verb surface
(`tasks/cancel` → `claude-interrupt`), add the **push-notification** webhook leg (so the broker can fan out
async task updates instead of holding streams), then stand up the broker + register a Claude node and a
non-Claude node and drive them from one surface.

## Headless / autonomous runtime — SOLVED (2026-06-04)

A fully headless build → deploy → test loop with **no Anypoint Studio**, enabling autonomous Mule iteration.
The recipe (verified end to end: clean boot, real Claude call through it, hot-redeploy in ~2 s):

1. **JDK 17.** Mule 4.11 needs Java 17; this box's PATH default `java` is Java 8. Set `JAVA_HOME` to
   `C:\Program Files\Eclipse Adoptium\jdk-17.0.5.8-hotspot` for every `mvn`/`mule.bat` call. (Helper scripts do.)
2. **Build:** `mvn clean package` (JDK 17 + the existing `~/.m2/settings.xml` Exchange/EE creds) → the
   `-mule-application.jar`.
3. **Clean standalone runtime — NOT Studio's.** Download
   `com.mulesoft.mule.distributions:mule-ee-distribution-standalone:4.11.4:zip` (`mvn dependency:get`, EE creds)
   and extract to a user-writable dir → `D:\mule-ee\mule-enterprise-standalone-4.11.4`. Runs on a 30-day eval
   license out of the box. `wrapper.java.command=%JAVA_HOME%/bin/java` (no bundled JDK → relies on `JAVA_HOME`).
4. **Configure once:** `wrapper.conf` → `wrapper.ping.timeout=300` (default 30 kills a slow/contended boot via
   `DUMP,RESTART`) and `wrapper.java.additional.101=-Dclaude.apiKey=<key>` (`ignore_sequence_gaps=TRUE`, so any
   index works). Drop the app jar into `apps\`.
5. **Run in CONSOLE mode** (`mule.bat console`), launched from a background shell (the `mule-headless-dev`
   skill's `start`). It stays up as long as the shell does. **Hot-redeploy** by copying a fresh jar into
   `apps\` (the skill's `redeploy`): the running runtime redeploys in place (~2–5 s; plugins stay cached),
   no restart.

**Two myths busted from the first attempt:**
- The repeated ~30 s deaths were **NOT process reaping** — a runtime *I* launch via a background shell boots
  and **stays up** across many tool calls and live requests. The deaths were entirely the next point:
- **DON'T copy Studio's embedded runtime** (`…AnypointStudio\plugins\…server.4.11.ee…\mule`). It is slaved to
  the IDE: standalone it reaches `DEPLOYED` then **self-terminates ~200 ms later** (`AgentStudioManagementService`
  teardown → shutdown hook) in *every* launch mode. A fresh standalone distribution has no such coupling.
- The **Windows service** path is also a dead end (admin `mule.bat install`/`start` hits the SCM ~30 s
  start-signal timeout → aborts); console mode under a background shell is the answer, no admin needed.

**Helpers:** the start/redeploy dev loop is provided by the `mule-headless-dev` Claude skill (build with
JDK 17 → hot-deploy → wait-until-ready). The repo's `scripts/` holds the `*-test.ps1` harnesses
(smoke / multiturn / stream / confirm / cancel) + `webhook-receiver.py`.
Loop = edit → skill `redeploy` → run a `scripts/*-test.ps1` → commit.
