# claude-a2a-adapter — the A2A wrapper (Mule 4)

A MuleSoft application that wraps an **Anthropic Claude Managed Agent** and exposes it as a fully
compliant **A2A (Agent-to-Agent) server**, using the MuleSoft A2A Connector. It's a pure **protocol
adapter** (A2A Task semantics on the front, Claude session events on the back) with **no business
logic** — point `agentId`/`environmentId` at a different agent and you've replicated it.

## Prerequisites

- **Java 17** + Maven.
- **MuleSoft Exchange credentials** in your `~/.m2/settings.xml` (the A2A connector is a **beta** asset).
- An `agentId` + `environmentId` from [`../claude-agent/`](../claude-agent/) (`ids.json`).
- A Claude API key (passed at runtime; see Config).

## Configure (copy the templates)

Config is **layered**: `config/common.yaml` (env-agnostic) + `config/env/<env>.yaml` (per-env, non-secret)
+ `config/secure/<env>.yaml` (secrets). The real `local.yaml`/`prod.yaml` are **gitignored** — only the
`*.example` templates are committed, so copy them:

```bash
cd src/main/resources/config
cp env/local.yaml.example       env/local.yaml        # set your agentId / environmentId / cardUrl
cp secure/local.yaml.example    secure/local.yaml     # (or pass -Dclaude.apiKey at launch instead)
```

The active env is chosen by `-M-Denv=<env>` (default `local`). The API key resolves as
`p('claude.apiKey') default p('secure::claude.apiKey')`, so `-M-Dclaude.apiKey=sk-ant-…` wins when set.
Full details + the CloudHub Runtime-Manager overrides: **[../docs/CONFIG.md](../docs/CONFIG.md)**.

## Build & run

```bash
mvn clean package                                  # -> target/*.jar
# Run locally with Anypoint Studio, the mule-headless-dev workflow, or deploy the jar to CloudHub.
# Quick local run example:
#   mule -M-Dclaude.apiKey=sk-ant-... (or set it in config/secure/local.yaml)
```

The A2A server listens on `a2a.server.path` (default `/a2a`); the agent card is discoverable at
`<base>/a2a/.well-known/agent-card.json`. See **[../docs/USAGE.md](../docs/USAGE.md)** for the A2A client guide.

## What's inside (`src/main/mule/`)

| File | Role |
|---|---|
| `global.xml` | Configs + the **inline agent card** (uses `${a2a.server.cardUrl}`). |
| `claude-client.xml` | REST/SSE client to the Claude Managed Agents API. |
| `a2a-server.xml` | Blocking `message/send` → create-or-resume → poll-to-end-of-turn → A2A Task. |
| `a2a-stream.xml` | Streaming `message/stream` relay (live `working` updates, per-tool-use, artifact, `completed`). |
| `a2a-taskstate.xml` | `contextId → sessionId` + pending-task state (Object Store) for HITL resume. |
| `confirmation.xml` | Tool-confirmation resolver (`defer`/`allow`/`deny` + per-tool globs) → A2A `input-required`. |
| `a2a-authorize.xml` | Resume/authorize round-trip for the HITL `input-required` flow. |
| `a2a-diag.xml` | **Optional** server-side `/diag/fetch` probe (gated by `diag.enabled`). **Self-contained — delete this one file for a diagnostics-free build** (more secure than the flag). |

## Features

Blocking + streaming responses · HITL via tool-confirmation → A2A `input-required` with **single-approve
resume** · **MCP tool-use governance** (per-tool allow/deny globs + `confirmation.default`) · inline,
config-driven agent card · `tasks/cancel` → interrupt.

## Optional demo UI

A Vue console lives in [`../demo-ui/`](../demo-ui/). Run its `embed/embed.ps1` (or `.sh`) to build it and
sidecar it into this app (served at the root path). The build outputs (`src/main/resources/dist/` +
`src/main/mule/a2a-ui.xml`) are gitignored — delete them to remove the demo.

More: [../docs/DESIGN.md](../docs/DESIGN.md) (architecture) · [../docs/CONFIG.md](../docs/CONFIG.md) ·
[../docs/USAGE.md](../docs/USAGE.md) · [../docs/STUDIO-VALIDATION.md](../docs/STUDIO-VALIDATION.md).
