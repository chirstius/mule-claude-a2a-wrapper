# Anypoint Studio validation pass

Goal: confirm the **beta A2A Connector DSL** and the **listener response-shape contract** are correct,
before we build the streaming + confirmation flows on top. The app is designed to **start and serve the
agent card without any secret**, so you can validate the DSL even before wiring credentials.

## 0. Prerequisites

- Anypoint Studio with a Mule runtime that satisfies `mule-artifact.json` (`minMuleVersion: 4.9.0`).
  If your Studio runtime differs, set `minMuleVersion` to match, or let the A2A Connector dictate the
  minimum (it may require a specific runtime — adjust if deploy complains).
- The A2A Connector is **beta**; the `pom.xml` versions (`a2a 1.1.0`, `http 1.10.3`, `objectstore 1.3.0`)
  are best-guess. If Maven can't resolve them, see step 2.

## 1. Import

`File ▸ Import ▸ Anypoint Studio ▸ Anypoint Studio project from File System`, point at:
`<repo-root>/claude-a2a-adapter`

(Studio will run a Maven update. If it imports as a plain Maven project instead, that's fine too.)

## 2. Resolve connectors if needed

If the A2A / HTTP / Object Store modules show as unresolved:
- Open `global.xml` in the visual editor and use **Add Modules** (Mule Palette ▸ Search in Exchange) to add
  **A2A Connector**, **HTTP**, and **Object Store**. Studio writes the **correct** versions into `pom.xml`.
- Reconcile any version my `pom.xml` guessed wrong against what Studio installs.

> This step is itself a validation result: note the **actual** connector version that resolves.

## 3. Deploy (DSL check — no secret required)

`Run ▸ Run As ▸ Mule Application`. Watch the console for `DEPLOYED`.

**What this proves:** the namespaces, `a2a:server-config` / `a2a:connection` / `a2a:agent-card`, the
`a2a:task-listener` source, the `os:object-store` elements, and the `http`/`ee` DSL all parse against the
installed connector schemas. Any red X in the editor or a schema error on deploy is a DSL finding to fix.

## 4. Validate endpoints

With the app deployed, run the helper (from the repo root):

```powershell
.\scripts\local-test.ps1
```

It does two things:

**(a) GET `/.well-known/agent-card.json`** — should return the card from `src/main/resources/agent-card.json`.

**(b) POST `message/send`** (JSON-RPC) to `/a2a` — triggers the `a2a-message-send` flow.
To make (b) actually reach Claude, deploy with the key as a VM arg:
`Run config ▸ Arguments ▸ VM args:`  `-M-Dclaude.apiKey=sk-ant-...`
(Without it, the flow starts but the first HTTP call to Anthropic returns an auth error — still useful to
confirm the flow wiring and the response envelope.)

## 5. The open questions to answer (the point of this pass)

Record findings against each — these drive the next build steps:

1. **Agent-card file resolution.** `global.xml` uses
   `<a2a:agent-card file="${app.home}/agent-card.json"/>` (per the connector docs, recommended for
   CloudHub). If the card 404s locally, the file isn't at `${app.home}`. Try instead:
   - `file="agent-card.json"` (classpath/relative), or
   - copy `agent-card.json` to the app's working dir.
   Note which value actually serves the card in Studio.

2. **Listener response contract (the big one).** The `a2a-message-send` flow ends by setting `payload`
   to an A2A result object (`status: completed`, `message`, `artifacts`). Confirm whether the
   `a2a:task-listener` **returns that payload as the JSON-RPC result**. Inspect `local-test.ps1`'s printed
   response:
   - If the response already contains our text/artifacts → the "return payload" assumption is correct.
   - If not, the connector likely expects explicit emission — switch the finalize step to
     `<a2a:update-task-status>` (state `completed`) + `<a2a:update-task-artifact>` (same pattern the
     streaming flow will use). Note which is right.

3. **Incoming payload accessors.** Add a `<logger message="#[write(payload,'application/json')]"/>` right
   after the `task-listener` and confirm the real fields: `payload.id` (taskId), `payload.contextId`,
   `payload.message.parts[].text` (and the part discriminator — `kind` vs `type`). Adjust the
   `set-variable`s if reality differs.

4. **Connector element/attribute names.** Confirm the installed connector accepts: `a2a:server-config`,
   `a2a:connection@listenerConfig/@agentPath`, `a2a:agent-card@file`, `a2a:task-listener@config-ref`.
   Note any renamed/required attributes (beta drift).

5. **Polling pattern.** Confirm `until-successful` + `raise-error` (APP:SESSION_NOT_IDLE) retries cleanly
   and that `payload` after the loop is the idle session object (so `usage` reads correctly).

## 6. Report back

Paste: the resolved connector version (step 2), the `local-test.ps1` output (step 4), and your notes on
items 1–5. That tells me exactly what to adjust before building the streaming and confirmation flows.
