# Usage — Claude Managed Agent over A2A (MuleSoft wrapper)

How to call the wrapper as an A2A client, and how to configure/run it. The wrapper is an **A2A
server** (JSON-RPC 2.0 over HTTP) in front of a Claude managed agent. Verified on A2A connector
**1.1.1**, Mule **4.11**, Java **17**.

- Base URL (local): `http://localhost:8081`
- A2A endpoint: `POST /a2a`
- Agent card: `GET /a2a/.well-known/agent-card.json`

All examples use the JSON-RPC envelope `{"jsonrpc":"2.0","id":"<any>","method":"<m>","params":{…}}`.

---

## 1. Discover — agent card

```bash
curl -s http://localhost:8081/a2a/.well-known/agent-card.json
```
Returns the A2A `AgentCard` (name, capabilities, skills). `capabilities.streaming: true`. A
tool-confirmation **extension** is advertised under `capabilities.extensions` (see §5).

## 2. Blocking — `message/send`

Send a message, get the finished `Task` back synchronously.

```bash
curl -s -X POST http://localhost:8081/a2a -H "content-type: application/json" -d '{
  "jsonrpc":"2.0","id":"1","method":"message/send",
  "params":{"message":{"role":"user","kind":"message","messageId":"<uuid>",
    "parts":[{"kind":"text","text":"In one sentence, what is the A2A protocol?"}]}}}'
```
Response: a `Task` with `status.state:"completed"` and an `artifacts[]` "Answer" part. Files the
agent writes come back as additional artifacts (one per file, deduped to last-write).

## 3. Streaming — `message/stream`

Same params, but the response is an **SSE** stream of A2A events: `task` (submitted) → `status-update`
(`working`, with a relayed "Using tool: …" message per tool call) → `artifact-update` (the Answer)
→ terminal `status-update` (`completed`, `final:true`). Use an SSE client (e.g. `curl -N`).

```bash
curl -N -s -X POST http://localhost:8081/a2a \
  -H "content-type: application/json" -H "accept: text/event-stream" -d '{…message/stream…}'
```

## 4. Multi-turn — reuse `contextId`

Set the same `message.contextId` across calls to continue the conversation (the wrapper maps
`contextId → Claude session`, so the agent remembers prior turns).

```bash
# turn 1
... "message":{ … ,"contextId":"ctx-abc","parts":[{"kind":"text","text":"My favorite number is 42."}]}
# turn 2 (same contextId) -> the agent recalls "42"
... "message":{ … ,"contextId":"ctx-abc","parts":[{"kind":"text","text":"What is my favorite number?"}]}
```

## 5. Human-in-the-loop — tool confirmation (`input-required`)

When the wrapped agent's tools require approval (an `always_ask` permission policy) and the wrapper's
`confirmation.default` is `defer`, a tool call pauses the task into A2A **`input-required`**, carrying a
standard `DataPart`:

```json
{ "kind":"data", "data":{ "type":"tool-confirmation-request", "taskId":"…",
  "calls":[{ "toolUseId":"sevt_…", "name":"write", "toolType":"agent.tool_use",
             "key":"tool_use:write", "input":{ "file_path":"…","content":"…" } }] } }
```

Answer by sending a message on the **same `contextId`** with a response `DataPart`; the task resumes:

```json
{ "kind":"data", "data":{ "type":"tool-confirmation-response",
  "decisions":[{ "toolUseId":"sevt_…", "result":"allow" }] } }      // or "deny" + "denyMessage"
```

Policy (server-side, see `confirmation.*` config): `deny`-list wins, then `allow`-list, else
`default` (`defer` | `allow` | `deny`). `allow`/`deny` are auto-applied inline (no caller round-trip);
only `defer` surfaces `input-required`.

## 6. Cancel — `tasks/cancel`

```bash
curl -s -X POST http://localhost:8081/a2a -H "content-type: application/json" -d '{
  "jsonrpc":"2.0","id":"c","method":"tasks/cancel","params":{"id":"<taskId>"}}'
```
Marks the task `canceled` **and** sends `user.interrupt` to the underlying Claude session so the agent
actually stops (not just a cosmetic state change). Most useful against a streaming task (you get the
`taskId` from the first stream event).

## 7. Not yet supported

- **Push notifications** (webhook delivery). The connector requires a `push-notification-config-listener`
  and the card flag, but the correct end-to-end delivery pattern isn't wired yet — see DESIGN.md
  "Push notifications" open item. The card advertises `pushNotifications: false` accordingly.

---

## Configuration (`src/main/resources/config/`)

Config is **layered and environment-aware** — `common.yaml` (env-agnostic) + `env/<env>.yaml`
(per-environment, non-secret) + `secure/<env>.yaml` (secrets, via the Secure Properties module).
The active environment is chosen by `env` (default `local`; `-M-Denv=prod` to switch). **Full
details in [CONFIG.md](./CONFIG.md).** The knobs you'll touch most:

- `claude.agentId` / `claude.environmentId` (`env/<env>.yaml`) — the Claude managed agent + environment
  to wrap. The POC agent's toolset is **`always_ask`**, so every tool surfaces to the wrapper's
  `confirmation` policy. With the demo defaults that yields all three paths from one agent: a `read`
  request **auto-runs**, a `write` surfaces the **`input-required` approval** (HITL), and a `bash`
  request is **auto-denied** — see `confirmation.{allow,deny}` below.
- `claude.apiKey` (`secure/<env>.yaml`) — **secret**. Resolved as
  `p('claude.apiKey') default p('secure::claude.apiKey')`: pass `-M-Dclaude.apiKey=…` for local, or
  store an AES-encrypted `![…]` token in the secure file for prod. Never commit a real key.
- `confirmation.default` (`env/<env>.yaml`) — `defer` (HITL) | `allow` (auto-approve) | `deny`;
  `confirmation.allow`/`deny` (`common.yaml`) are CSV glob patterns over tool keys
  (`tool_use:<name>`, `mcp_tool_use:<server>/<name>`).
- `a2a.server.listener.port` (`env/<env>.yaml`, default `8081`), `a2a.server.path` (`common.yaml`, `/a2a`).

## Timeouts

A blocking `message/send` (and the open SSE for `message/stream`) is held for the **whole turn** —
the wrapper does not return until the Claude session goes idle (bounded only by the Claude SSE
`responseTimeout`). The wrapper's own HTTP listener never times out a running flow.

So the constraint lives **in front of** the wrapper: any intermediate hop (Flex Gateway, load
balancer, reverse proxy) **and the calling client** must set a read/idle timeout long enough to
cover the longest expected turn, plus headroom. A turn that does real tool work can run minutes;
budget accordingly (e.g. longest-expected-turn + ~30s buffer). If an upstream read timeout is too
low it will sever the connection mid-turn even though the wrapper is still working.

## Running it (no Anypoint Studio)

Use the **`mule-headless-dev`** skill: build with JDK 17, run a clean standalone Mule EE runtime,
hot-deploy the jar, and exercise with the `scripts/*-test.ps1` harnesses (`local-test`,
`multiturn-test`, `stream-test`, `confirm-test`, `cancel-probe`). See DESIGN.md
"Headless / autonomous runtime — SOLVED".

## Connector compatibility note (1.1.1)

A2A connector **1.1.1** strictly validates that a response `Task`'s `id`/`contextId` **match the
request's** (it rejects a mismatch with JSON-RPC `-32005`/`-32603` "Request and response task id or
context id … don't match"). The wrapper therefore builds responses with the connector-assigned
`attributes.taskId` / `attributes.contextId` (both blocking and streaming flows), not a self-minted id.
