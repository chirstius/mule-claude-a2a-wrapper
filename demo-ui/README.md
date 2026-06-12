# Claude A2A — Demo UI (technology demonstrator)

A small Vue 3 + Vite single-page app that chats with the wrapped Claude agent over **A2A** and
visualizes every feature the wrapper implements: blocking **and** streaming, live state changes,
tool-usage relays, **tool approvals (HITL `input-required`)**, `tasks/cancel`, artifacts, and a
push-notification stub.

It's a **pure A2A client** — it only speaks JSON-RPC to the wrapper's `/a2a` endpoint. Nothing
server-side is required beyond the wrapper itself.

## Run it standalone (dev)

```bash
cd demo-ui
npm install
npm run dev            # http://localhost:5173
```

The Vite dev server **proxies `/a2a` → `http://localhost:8081`** (your local headless wrapper), so
the browser stays same-origin and there's no CORS. Start the wrapper first (mule-headless-dev skill).

- **Point at a different wrapper:** either change the proxy target in `vite.config.ts`, or type an
  absolute base URL into the **endpoint** field in the header (e.g. the CloudHub URL). Note: an
  absolute cross-origin URL requires the wrapper to send CORS headers — same-origin (the dev proxy or
  the embedded root build) avoids that entirely.
- **HITL:** point the wrapper at the **`always_ask`** confirm agent (see `claude-a2a-adapter`
  `config/env/<env>.yaml` + `docs/CONFIG.md`) so gated tools surface as approval cards.

## Build

```bash
npm run build       # multi-asset SPA -> dist/   (host anywhere, or embed in the wrapper)
npm run typecheck   # vue-tsc --noEmit
```

## Embed into the wrapper (served at the app root `/`)

The embed is **optional and self-contained**: the built `dist/` is served by Mule's
`http:load-static-resource` (one flow, `embed/a2a-ui.xml`) at the app root, same-origin with `/a2a`
(no CORS). A2A requests on `/a2a` stay owned by the connector (more specific path); every other path
falls back to `index.html` (SPA).

```bash
# from demo-ui/
./embed/embed.sh          # or:  pwsh ./embed/embed.ps1   (Windows)
# -> npm run build, copies dist/ to the wrapper's src/main/resources/dist/,
#    and drops embed/a2a-ui.xml into the wrapper's src/main/mule/
# then rebuild/redeploy the wrapper and open  http://<host>/
```

**To remove the demo from a wrapper instance** (when you don't need it) — one folder, one flow:

```
rm claude-a2a-adapter/src/main/mule/a2a-ui.xml
rm -r claude-a2a-adapter/src/main/resources/dist
```

That's it — no other wrapper code references it. (Both paths are gitignored in the wrapper, so the
embed never pollutes the committed app.)

## What you'll see

| Feature | Where |
|---|---|
| Blocking ↔ streaming | toggle in the header |
| Multi-turn memory | `contextId` reused across messages (sidebar shows it) |
| Live state changes | status pill per turn + the event timeline |
| Tool-usage relays | "Using tool: …" chips (streaming) |
| **Tool approvals (HITL)** | an approval card on `input-required`; Allow/Deny → `tool-confirmation-response` |
| Cancel | the Cancel button while working → `tasks/cancel` (+ client-side stream abort) |
| Artifacts | the Answer + any file artifacts (with download) |
| Push (stub) | sidebar panel — inert until the connector push model lands |

## Layout

```
src/
  a2a/            pure A2A client (framework-agnostic, reusable)
    types.ts      protocol + tool-confirmation types
    sse.ts        fetch() ReadableStream -> SSE event parser (POST streams)
    client.ts     message/send, message/stream, tasks/cancel
  composables/
    useA2A.ts     reactive store: turns, event reducer, actions
  components/
    TurnView.vue ApprovalCard.vue StatusPill.vue PushPanel.vue
  App.vue main.ts styles.css
embed/
  a2a-ui.xml      Mule flow: http:load-static-resource serving dist/ at the app root (SPA)
  embed.ps1 / embed.sh   npm run build + copy dist/ into the wrapper
```

The `a2a/` folder is intentionally decoupled — the same client logic could back a different
front-end (e.g. a Slack Block Kit renderer).
