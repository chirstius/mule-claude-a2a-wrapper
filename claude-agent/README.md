# claude-agent — the Claude-side backend

Declarative definitions + scripts to create and test the **Anthropic Claude Managed Agent** that the
[A2A wrapper](../claude-a2a-adapter/) fronts. You can stand this up and exercise it **without Mule** —
giving you a known-good target before wiring up the wrapper.

## Prerequisites

- An **Anthropic account** with **Managed Agents (beta)** access, and an **API key**.
- PowerShell 5.1+ (`*.ps1`) or bash + curl (`*.sh`).

## Files

| File | What it is |
|---|---|
| `agent.json` | Declarative **managed-agent** definition (name, model, system prompt, toolset). |
| `environment.json` | Declarative **cloud sandbox** (environment) definition. |
| `setup.ps1` / `setup.sh` | Create the environment + agent, then save the resulting IDs. |
| `smoke-test.ps1` | Create a session, send a prompt, print the agent's reply + token usage. |
| `teardown.ps1` | Archive / delete the created resources. |
| `.env.example` | Copy to `.env` and add your `ANTHROPIC_API_KEY`. |

## Usage

```powershell
cp .env.example .env          # then edit .env and paste your ANTHROPIC_API_KEY
./setup.ps1                   # creates the environment + agent; writes ids.json (+ .env.local)
./smoke-test.ps1              # verifies the agent responds end-to-end (no Mule needed)
# ...
./teardown.ps1               # when you're done, clean up the created resources
```

`setup.ps1` **reuses** an environment with the same name if it exists, but creates a **new agent** each
run (agents aren't name-unique). The generated **`ids.json`** holds the `agentId` and `environmentId` —
copy those into the wrapper's `config/env/local.yaml` (see [claude-a2a-adapter](../claude-a2a-adapter/)).

> `.env`, `.env.local`, and `ids.json` are **gitignored** — they hold your key and account-specific IDs.

See the root [README](../README.md) for how this backend maps to A2A Task semantics.
