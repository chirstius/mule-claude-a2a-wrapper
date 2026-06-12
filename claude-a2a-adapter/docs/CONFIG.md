# Configuration

The wrapper is configured with **layered, environment-aware** property files plus the
Mule Secure Properties module. The active environment is chosen by the `env` property
(default `local`; override at deploy with `-M-Denv=prod` or a CloudHub property).

| File | Holds | Committed? |
|------|-------|-----------|
| `src/main/resources/config/common.yaml` | env-agnostic settings (same everywhere) | yes |
| `src/main/resources/config/env/<env>.yaml` | per-environment **non-secret** values (ports, agent ids, the card url) | yes (real values) |
| `src/main/resources/config/secure/<env>.yaml` | secrets (`claude.apiKey`) as `![…]` tokens | yes (encrypted) |

> **Each property key must appear in exactly ONE file.** Mule layers the providers into a
> single flat namespace; it does not merge a key redefined across files.

YAML values are validated as **strings** by the config-properties provider, so **quote every
scalar** (`port: "8081"`, not `8081`).

---

## The A2A Agent Card

The connector publishes the agent's [AgentCard](https://a2a-protocol.org) at
`<agentPath>/.well-known/agent-card.json`. The card is served **inline** from `global.xml`:

```xml
<a2a:server-config name="A2A_Server_config">
    <a2a:connection listenerConfig="HTTP_Listener_config" agentPath="${a2a.server.path}"/>
    <a2a:agent-card>
        <a2a:json><![CDATA[{
  "protocolVersion": "0.3.0",
  "name": "Claude Managed Agent (A2A)",
  "description": "...",
  "url": "${a2a.server.cardUrl}",
  "version": "0.1.0",
  ...
}]]></a2a:json>
    </a2a:agent-card>
</a2a:server-config>
```

### Why inline (and not a file)

The connector's `<a2a:agent-card>` has two mutually-exclusive forms — `file="…"` (a path) and
`<a2a:json>…</a2a:json>` (the card inline). **Only the inline form participates in Mule property
resolution**: the `file` form is read as raw bytes (no `${…}` substitution), and the `json`
parameter rejects `#[…]` DataWeave expressions. So to make any part of the card configurable per
deployment, the card must be **inline** and use **`${…}` property placeholders**.

### Setting the card URL — `a2a.server.cardUrl`

The card's own public `url` (where clients/brokers reach this agent) is the one field that changes
between environments. It is injected from a single property:

```yaml
# config/env/<env>.yaml
a2a:
  server:
    cardUrl: "https://my-agent.cloudhub.io/a2a"   # local dev: http://localhost:8081/a2a
```

- **The property must be defined** — Mule `${…}` has no inline default. An unset `cardUrl`
  fails deployment with *"Could not resolve placeholder 'a2a.server.cardUrl'"*. Set it to the
  card's intended url (locally that's `http://localhost:<port>/a2a`).
- **CloudHub:** override `a2a.server.cardUrl` in **Runtime Manager → Properties** to repoint the
  card **without a rebuild/redeploy**.
- Only the **top-level** `url` is a placeholder; `provider.url` and extension `uri`s stay literal.

> **Consumer-side trailing slash (the discovery 404 trap).** An A2A client/broker discovers the
> card by resolving `.well-known/agent-card.json` **relative** to the URL it was given for this
> agent — so that URL **must end with a trailing `/`**. We serve the card under `agentPath=/a2a`
> at `/a2a/.well-known/agent-card.json`; if a consumer is pointed at `…/a2a` (no slash), RFC 3986
> relative resolution drops the last segment and it requests `…/.well-known/agent-card.json` at the
> host root → `404 Agent card not found`. In a MuleSoft **agent network**, this means the
> `connections.*.spec.url` in `exchange.json` must be `…/a2a/`, not `…/a2a`. (MuleSoft's own
> troubleshooting guide: *"Check that the URL you set on the connection ends with a `/`."*) The
> card's *self-advertised* `url` above does not need the slash — only the URL the consumer resolves
> the well-known path against does.

### Customizing the card (the template)

`src/main/resources/agent-card.template.json` is a ready-to-edit sample with the
`"url": "${a2a.server.cardUrl}"` placeholder already embedded. To stand up a new agent:

1. Copy `agent-card.template.json` and edit `name`, `description`, `skills`, etc. **Keep
   `"url": "${a2a.server.cardUrl}"` as-is.**
2. Paste the edited JSON into the `<a2a:json><![CDATA[ … ]]></a2a:json>` slot in `global.xml`.
3. Set `a2a.server.cardUrl` in `config/env/<env>.yaml` for each environment.

> The template file is **not read at runtime** — it is only a copy/paste source. The live card is
> the inline `<a2a:json>` block. (There is intentionally no standalone `agent-card.json`: a file the
> connector ignored would invite drift.)
>
> **CDATA caveat:** the card JSON must not contain the sequence `]]>`. Standard cards never do.

---

## Other notable properties

| Key | File | Purpose |
|-----|------|---------|
| `a2a.server.path` | common | A2A base path the connector serves on (`agentPath`). |
| `a2a.server.listener.host` / `.port` | env | Inbound HTTP listener bind. |
| `claude.agentId` / `claude.environmentId` | env | The managed agent this wrapper fronts. |
| `claude.apiKey` | secure (or `-M-Dclaude.apiKey`) | Anthropic API key; the `-D` override wins. |
| `confirmation.allow` / `.deny` | common | Tool-confirmation allow/deny-list (glob patterns). |
| `confirmation.default` | env | Posture when no list matches: `defer` (HITL) / `allow` / `deny`. |
| `diag.enabled` | env | Exposes the `/diag/fetch` probe + DIAG logging. **Keep `"false"` in prod.** |
