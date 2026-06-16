# Claude Managed Agent ⟷ A2A Wrapper (MuleSoft)

A lean, portable MuleSoft application that wraps an **Anthropic Claude Managed Agent** and exposes it
as a fully compliant **A2A (Agent-to-Agent) server**, using the MuleSoft A2A Connector.

The wrapper is a pure **protocol adapter**: A2A Task semantics on the front, Claude session events on
the back. It carries no business logic, so it stays copyable — point it at a different Claude agent /
environment and you have replicated it.

```
A2A client / orchestrator                 Mule wrapper (this project)            Claude Managed Agents API
        │  A2A over HTTP(S)                       │  REST + SSE                            │
        │  • agent card discovery     ──────▶     │  • Task Listener (message/send)        │  POST /v1/sessions
        │  • message/send | message/stream        │  • Task Stream Listener (message/stream)│  POST /v1/sessions/{id}/events
        │  • tasks/get | tasks/cancel             │  • contextId → sessionId store    ──────▶  GET  /v1/sessions/{id}/events/stream
        │  • input-required round-trip            │  • confirmation resolver               │  user.message / interrupt / tool_confirmation
        ▼                                         ▼                                        ▼
```

## Downloads (pre-built jars)

Don't want to build from source? The [**latest release**](https://github.com/chirstius/mule-claude-a2a-wrapper/releases/latest)
attaches ready-to-run Mule application archives — import them via
`File ▸ Import ▸ Anypoint Studio ▸ Packaged Mule application (.jar)` (Studio / Anypoint Code Builder), or
deploy straight to a Mule 4 runtime:

- **`…-mule-application.jar`** — the wrapper alone.
- **`…-mule-application-with-ui.jar`** — the wrapper plus the embedded demo console (served at `/`).

Both bundle their dependencies and include project sources (`META-INF/mule-src`), so they import as fully
editable projects. They ship with **placeholder** config and **no API key** — set your own
`claude.agentId` / `claude.environmentId` and key before running (see [docs/CONFIG.md](docs/CONFIG.md)).

## Repository layout

```
.
├── README.md                     ← you are here
├── docs/
│   ├── CONFIG.md                 ← config layout, env toggle, secure properties
│   └── USAGE.md                  ← A2A client guide + how to run it
├── claude-agent/                 ← the Claude-side backend (the testable target)
│   ├── environment.json          ← cloud sandbox definition (declarative)
│   ├── agent.json                ← managed agent definition (declarative)
│   ├── setup.ps1 / setup.sh      ← create environment + agent, save IDs
│   ├── smoke-test.ps1            ← verify the agent responds (no Mule needed)
│   ├── teardown.ps1              ← archive/delete the created resources
│   └── .env.example              ← copy to .env, add your ANTHROPIC_API_KEY
├── claude-a2a-adapter/           ← the A2A wrapper (Mule 4 application)
│   ├── pom.xml                    ← Mule app + connector/module deps (a2a, http, objectstore, secure-props)
│   ├── mule-artifact.json
│   └── src/main/
│       ├── mule/                  ← flows: global, claude-client, a2a-server / a2a-stream / a2a-authorize, confirmation
│       └── resources/
│           ├── agent-card.template.json ← copy/paste card template; the live card is served INLINE from global.xml via ${a2a.server.cardUrl}
│           └── config/            ← layered config: common.yaml + env/<env>.yaml + secure/<env>.yaml
└── scripts/                      ← test helpers (NOT part of the Mule app; dev loop = mule-headless-dev skill)
    ├── local-test.ps1 / multiturn-test.ps1 / stream-test.ps1   ← exercise the deployed server
    ├── confirm-test.ps1 / confirm-stream-test.ps1 / cancel-probe.ps1
    └── webhook-receiver.py        ← push-notification test sink
```

## Quick start (Claude backend first)

The Claude managed agent can be created and tested **independently of Mule**. Do this first so you have a
known-good target before wiring up the wrapper.

```powershell
cd claude-agent
Copy-Item .env.example .env
# edit .env and paste your ANTHROPIC_API_KEY
.\setup.ps1            # creates the environment + agent, writes ids.json + .env.local
.\smoke-test.ps1       # creates a session, sends a prompt, prints the agent's reply + token usage
```

`setup.ps1` reuses the environment if one with the same name already exists, but creates a **new agent**
each run (agents aren't name-unique). Use `teardown.ps1` to clean up, or just reuse the IDs in `ids.json`.

## Features

- **Blocking `message/send`** — create-or-resume → poll-to-end-of-turn → A2A Task with the agent's answer.
- **Streaming `message/stream`** — live `working` updates, per-tool-use relay over SSE, answer artifact, `completed`.
- **Multi-turn sessions** — `contextId → sessionId` continuity across turns.
- **Human-in-the-loop** — tool-confirmation → A2A `input-required` with single-approve resume; `tasks/cancel` → interrupt.
- **MCP tool-use governance** — per-tool allow/deny globs + a `confirmation.default` (`defer` / `allow` / `deny`).
- **Inline, config-driven agent card** — served from `global.xml` via `${a2a.server.cardUrl}`.
- **End-to-end validated** through a real A2A broker / multi-agent orchestrator.
- ⚠️ **Push notifications** — config-listener + card flag present; one integration gap remains.

## Key design rules

- **`contextId → sessionId`** is the conversation keystone; persisted in an Object Store.
- **The terminal answer must land in durable task state** (final artifact / `completed` status message),
  never only in a streamed `working` update — so blocking and polling clients don't lose it.
- **Artifacts come from file-write tool-use events** in the session, one `artifact-update` per file.
- **Tool confirmations** resolve via a config default (`defer` | `allow` | `deny`) with optional per-tool
  override lists; `defer` surfaces the call to the caller as A2A `input-required` (protocol-native HITL).
- **Blocking `message/send` polls the event stream** until a *new* end-of-turn marker appears (the backend
  is async; a fresh session is already `idle`, so status-polling would exit early). Retry budget is config
  (`claude.poll.maxRetries` × `claude.poll.intervalMs`, ~5 min default). Our HTTP listener holds the
  connection open for the whole flow — no server-side timeout — so set the *upstream* gateway/LB/caller
  read timeout to `(maxRetries × intervalMs) + a2a.server.callerTimeoutBufferMs`.
