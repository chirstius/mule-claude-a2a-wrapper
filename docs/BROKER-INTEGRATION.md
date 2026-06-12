# Broker → Wrapper integration — findings & runbook

Status snapshot from the 2026-06-08 debugging session that took the agent-network broker
from "silently answers with its own model" to "genuinely calls the Claude agent, runs real
tool turns, and relays the HITL approval." Captures what works, the bugs found and fixed, the
gateway path behavior, how to tell a real agent answer from the broker's fallback, and a
runbook for re-verifying after an agent-network/Flex redeploy.

## Topology

```
client ──▶ Broker (ingress GW)            https://agent-network-ingress-gw-…/claude-broker/
                │  orchestration + its OWN OpenAI model
                ▼
           Egress GW (Flex)               https://agent-network-egress-gw-…internal-…/<basepath>/claude-agent/ClaudeAgentConnection
                │  path-rewrite ──▶ wrapper /a2a
                ▼
           Wrapper (this app)             https://claude-a2a-adapter-…/a2a   (public)   + internal-… (in-VPC)
                │
                ▼
           Claude Managed Agents API
```

The egress GW address is **internal** (VPC-only) — not reachable from a browser/external curl.
That's why we built the in-wrapper diagnostic (see "Diagnostic tooling").

## What works / what doesn't (end state)

| Capability | Status |
|---|---|
| Broker → egress GW → wrapper `/a2a` routing | ✅ |
| Real Claude agent turns + tool use via the broker | ✅ |
| Agent card fetch via egress (`/a2a/.well-known/agent-card.json`) | ✅ (after GW fix) |
| HITL `write` gate → `input-required` **relayed** through the broker | ✅ |
| HITL **approval → resume** through the broker | ✅ (2026-06-09) — was our wrapper requiring a bespoke DataPart; fixed by accepting A2A-spec plain-text continuation (see below) |
| Delegation with the regenerated (no-slash) card URL | ✅ broker handles it — *not* a blocker (see below) |
| Survives a stock agent-fabric redeploy | ✅ gateway→wrapper mapping preserved (only the broker's LLM config reset; see below) |

## Trace evidence (the proof — before vs after)

The whole fix is visible in one span: the `[Agent] claude-agent` duration. Distributed traces
of the same "delegate a task" request, before and after the fixes:

**Broken** (silent fallback — broker answered itself):
```
[Agent] claude-broker            22.91s   200
└ router … egress                22.90s
  └ mule:flow                    15.09s
    └ [BROKER] Claude_Broker     15.00s
      ├ [LLM] open-ai             2.63s   ← OpenAI produced the answer
      └ [Agent] claude-agent     13.32ms  ← fast-fail (404), never ran
```

**Valid** (real delegation — trace `b5d21fe0…`, Jun 8 2026 3:30 PM, 200 OK):
```
[Agent] claude-broker            26.42s   200
└ router … egress                26.42s
  └ mule:flow                    25.12s
    └ [BROKER] Claude_Broker     25.12s
      ├ [LLM] open-ai             1.72s   ← now just orchestration/routing
      └ [Agent] claude-agent     22.96s   ← REAL Claude agent turn
```

`claude-agent` went **13.32 ms → 22.96 s**, and the answer-producing work moved off OpenAI onto
the Claude agent. That single contrast is the end-to-end success criterion.

## How to tell a real agent answer from the broker's OpenAI fallback

The broker answers simple questions with **its own OpenAI model** and only delegates tasks it
can't do itself (e.g. file creation). Discriminators on the broker's response:

| Signal | Real Claude agent | Broker OpenAI fallback |
|---|---|---|
| `artifactId` | `answer-<taskId>` | bare UUID |
| artifact `name` | `"Answer"` | *(absent)* |
| latency | ~20–30 s | ~2–7 s |
| "who made you?" probe | Anthropic / Claude | **"OpenAI"** |

The model-identity probe ("Reply with ONLY the company that created you") is the cleanest
one-shot check. A **file-creation task** is the best forcing function to make the broker
delegate ("Create a file named X with content Y and report what you wrote").

## Bugs found & fixed (wrapper side)

All committed. The throughline: **the deployed CloudHub runtime is OLDER than the local
dev runtime (4.11.4)**, so DataWeave that resolves locally can throw on deploy.

1. **`taskRec` sentinel selector** (`a2a-server.xml`, `a2a-stream.xml`) — `vars.taskRec.pending`
   threw `Value Selector … String "__NONE__"` on a first/plain message (no prior state), failing
   the task after the answer had streamed. Fixed: guard `if (vars.taskRec is Object)`.

2. **Non-portable `import … from dw::core::Strings`** — the big one for HITL. `upper`/`lower`/`trim`
   are **Core** (auto-imported) functions; importing them from the Strings module resolves on
   4.11.4 but throws `Unable to resolve reference of: lower/trim` on the older deployed runtime.
   - `a2a-diag.xml` used `upper` (fixed first).
   - `confirmation.xml` used `import lower, trim from dw::core::Strings` — and the confirmation
     resolver runs on **every `write`→HITL path**, so *every tool task* threw there. Fixed: use the
     bare Core functions, no import.
   - **Rule:** never `import` `upper`/`lower`/`trim` from Strings — call them bare. (Captured in
     the global notes too.)

3. **Error response not serializable** (`a2a-server.xml` error handler) — the `failed`
   `status.message` was missing the required `kind: "message"` (and `messageId`), so the A2A
   connector couldn't serialize it → JSON-RPC **-32603 "missing 'kind'"**, which **masked** bug #2
   behind an unmarshalling error. Fixed: add `kind: "message"` + `messageId`. Every status message
   the wrapper emits must include `kind: "message"`.

Why only tool tasks failed: simple `completed` turns never touch the confirmation resolver, so
plain Q&A worked while a file-write task failed.

## Gateway path behavior (the routing saga)

The egress GW rewrites the agent path to the wrapper's `/a2a`. We reverse-engineered the
transform using the wrapper's diagnostic (it echoes the path it receives):

**Before the GW fix** — the rewrite concatenated `/a2a` + the suffix **without a separator
slash** (`wrapper_path = "/a2a" + lstrip(suffix, "/")`):

| broker/diag requested (suffix after `…/ClaudeAgentConnection`) | wrapper received | result |
|---|---|---|
| `/` (POST) | `/a2a` | ✅ real agent |
| `/.well-known/agent-card.json` | `/a2a`**`.`**`well-known/agent-card.json` | ❌ SPA 404 (slash eaten) |
| `/a2a/.well-known/agent-card.json` | `/a2a`**`a2a`**`/.well-known/…` | ❌ 404 (doubled `/a2a`) |

Two takeaways that drove the fixes:
- **The card was unreachable** via the egress at every path — the slash-eat makes `/a2a/<subpath>`
  structurally impossible. The broker fetches the card before calling, so this blocked everything.
- The `/a2aa2a/…` (**doubled `/a2a`**) is the smell that **`/a2a` was being applied in two layers**
  — both the agent-network/broker's notion of the A2A path *and* the Flex upstream. The A2A base
  must live in **one** place.

**After the user's GW fix** — the card resolves, but a brittle edge remains:

| via egress | result |
|---|---|
| card `…/ClaudeAgentConnection/.well-known/agent-card.json` | ✅ 200 real card |
| message POST `…/ClaudeAgentConnection/` (**trailing slash**) | ✅ 200 real agent |
| message POST `…/ClaudeAgentConnection` (**no slash**) | ❌ gateway 404 |

At the **raw HTTP level** the no-slash form 404s while the trailing-slash form works — but this
turned out **not to be a real blocker**. With the agent network regenerated and the card URL back
to **no trailing slash**, the broker still delegated end-to-end (file task → `input-required` from
the real agent). So the **broker normalizes/handles the path itself** (appends the slash, or routes
via the registry rather than the raw card URL) — the diag's no-slash 404 is a *lower-level probe
artifact* than what the broker actually sends. **No card edit is required for the broker path.**
(If you ever drive the agent from a client that does *not* normalize, routing both slash forms at
the gateway is still the robust belt-and-suspenders fix — but the network's own broker doesn't
need it.)

## Broker behavior (observed)

- **Reaches the agent regardless of card-URL trailing slash** — delegated end-to-end with the
  regenerated no-slash card URL (it normalizes the path itself).
- **Answers simple questions itself** via its own OpenAI model (by design — it's an orchestrator).
- **Delegates tasks it can't do** (file creation) to the registered claude-agent.
- **Relays `input-required`** (HITL) back to its caller — good, the human-approval surfaces.
- **Resumes a paused HITL session via a plain-text reply — RESOLVED 2026-06-09.** The earlier
  "broker answered 'Approved.' itself" was **NOT a broker limitation**; it was our wrapper
  *requiring* a bespoke `tool-confirmation-response` DataPart to resume, so the broker's natural
  plain-text "approve" was dropped and treated as a brand-new turn. After realigning to the A2A
  spec — resume on **pending-state presence** (not on the DataPart), accept a **plain-text
  approve/deny**, and **dual-key taskId+contextId** correlation (see `src/main/mule/a2a-taskstate.xml`)
  — the round-trip works end-to-end through the broker:
  ```
  file task                       -> input-required (our reworded prompt + tool-confirmation-request)
  reply "approve" (reuse broker    -> broker re-delegates to the paused wrapper session
   taskId + contextId)             -> completed, artifact "Created `broker-hitl.txt` containing … hello via broker"
  ```
  The completed result is the **real agent** confirming the actual write (exact content), not a
  self-answer. Verified directly against the public broker ingress on 2026-06-09.

Note: the old workaround of dropping the gate (`confirmation.allow: "tool_use:read,tool_use:write"`)
to force a one-shot `completed` is **no longer needed** — keep `write -> defer (HITL)`; the
approve→resume leg now carries through the broker.

## Diagnostic tooling — `/diag/fetch` (TEMPORARY)

`src/main/mule/a2a-diag.xml` adds a **server-side fetch proxy** so we can originate a request
from **inside** the private space (the wrapper) but trigger it from **outside** (browser address
bar or curl), and see the upstream status/headers/body verbatim. This is the only way to probe
the internal-only egress GW address.

- `GET  /diag/fetch?url=<urlencoded https cloudhub.io url>`
- `POST /diag/fetch?url=<…>&method=POST` (request body forwarded verbatim)
- Returns `upstreamStatus / upstreamContentType / upstreamHeaders / bodyPreview` (type-aware:
  JSON and HTML both render). Logs `DIAG >> inbound` / `DIAG << upstream` (category `DIAG`) to
  the app log — visible in the CloudHub log viewer.
- **SSRF-shaped: restricted to `*.cloudhub.io`. Diagnostic only — remove before any real
  exposure** (delete `a2a-diag.xml`).

Quick read of a `bodyPreview`: `text/html`/`<!doctype` = hit the SPA catch-all (wrong path);
`application/json` with `answer-` = real A2A; a Flex 404 with empty body = gateway-level reject.

## Runbook — re-verify after an agent-network / Flex redeploy

A "stock" agent-fabric redeploy regenerates the gateway mapping and **may revert the manual GW
path fix**. After redeploying the network, verify *in isolation* before involving the broker:

1. **Card via egress** (should be `200` + real card):
   `GET /diag/fetch?url=<egress-base>/.well-known/agent-card.json`
2. **Message via egress** (should be `200` + `answer-` artifact):
   `POST /diag/fetch?url=<egress-base>/&method=POST` with a `message/send` body.
   Also test the **no-slash** form `<egress-base>` — if it 404s, the trailing-slash brittleness
   is back.
3. Only if 1–2 pass, **hit the broker**: a model-identity probe (expect "OpenAI" on a *simple*
   question — that's the broker's by-design self-answer) and a **file-creation task** (the real
   delegation test — expect `input-required` with a well-formed tool-confirmation-request, not
   `-32603` or "issue accessing reasoning engine").

**Observed result of one stock agent-fabric redeploy (2026-06-08):** the deploy **preserved the
gateway→wrapper mapping** (steps 1–2 still passed, including the trailing-slash form), and
delegation worked end-to-end **even though the card URL regenerated without a trailing slash**.
The *only* thing it broke was the **broker's own LLM ("reasoning engine") config** — every broker
request failed with `"Cannot complete task due to issue accessing reasoning engine"` until the
broker's LLM settings were re-applied and it was redeployed. So: after a stock redeploy, suspect
**broker-side config reset first**, not the wrapper/gateway — and confirm the wrapper independently
with the diag (steps 1–2) so you can localize the break in seconds.

`<egress-base>` (format): `https://agent-network-egress-gw-<id>.internal-<space>.<region>.cloudhub.io/<orgId>/<agent>/<connection>`
Broker (format): `https://agent-network-ingress-gw-<id>.<space>.<region>.cloudhub.io/<broker>/`
Wrapper (public, format): `https://<wrapper-app>-<id>.<space>.<region>.cloudhub.io/`

## Open items

- ~~**HITL continuation through the broker**~~ — **RESOLVED 2026-06-09.** Approve→resume works
  end-to-end via a plain-text reply once the wrapper accepts A2A-spec continuation (resume on
  pending-state presence + dual-key taskId/contextId; see `src/main/mule/a2a-taskstate.xml` and the
  "Broker behavior" section). The fix was wrapper-side, not broker-side.
- **Broker LLM config resets on a stock redeploy** — the agent-fabric deploy resets the broker's
  reasoning-engine (LLM) settings; re-apply + redeploy the broker after each one. (Not a wrapper
  concern, but it's the thing that breaks the demo after a redeploy.)
- **Remove diagnostics before any real exposure** — delete `a2a-diag.xml`; harden the SPA flow to
  return 404 (not HTML 200) on non-`/a2a` paths (already queued as a follow-up task).
- **Runtime parity** — the CloudHub runtime is older than local 4.11.4; matching it locally would
  catch the `dw::core::Strings`-style portability traps before deploy instead of after.

### Resolved
- ~~Trailing-slash brittleness blocks delegation~~ — the raw no-slash 404 is a diag-probe artifact;
  the broker handles the no-slash card URL fine (verified after the stock redeploy). Routing both
  slash forms at the GW remains a nice belt-and-suspenders for non-normalizing clients, but is not
  required for the broker path.
- ~~Stock agent-fabric redeploy might revert the GW path mapping~~ — it didn't; the mapping was
  preserved. Only the broker's LLM config reset.
