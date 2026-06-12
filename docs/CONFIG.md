# Configuration — layered, environment-aware, secure

How the wrapper's configuration is organized, how to point it at a new environment, and how to
secure the API key. Verified on Mule **4.11**, Java **17**, A2A connector **1.1.1**, Secure
Configuration Properties module **1.2.7**.

## Layout

```
src/main/resources/config/
  common.yaml              # env-agnostic settings  (committed)
  env/
    local.yaml             # LOCAL non-secret values (committed — the dev default)
    prod.yaml.example      # PROD template          (committed)
    prod.yaml              # PROD real values        (gitignored — you create it)
  secure/
    local.yaml             # LOCAL secrets — plain placeholder (committed; no real secret)
    prod.yaml.example      # PROD secrets template   (committed)
    prod.yaml              # PROD real secrets        (gitignored — you create it)
```

Three providers are layered in `global.xml` into one flat property namespace:

```xml
<global-property name="env"        value="local"/>            <!-- default; -M-Denv=prod to switch -->
<global-property name="secure.key" value="devdevdevdev1234"/> <!-- dev default; -M-Dsecure.key=... in prod -->

<configuration-properties file="config/common.yaml"/>
<configuration-properties file="config/env/${env}.yaml"/>

<secure-properties:config name="Secure_Properties"
                          file="config/secure/${env}.yaml" key="${secure.key}">
    <secure-properties:encrypt algorithm="AES" mode="CBC"/>
</secure-properties:config>
```

**Rule: a property key lives in exactly ONE file.** The providers *layer*, they do not deep-merge,
so the same key defined twice is ambiguous. Keys that vary per environment (agent id, listener
port, HITL posture) live in `env/<env>.yaml`; everything constant lives in `common.yaml`;
secrets live in `secure/<env>.yaml`.

Every key below is actually consumed by a flow — the config carries no aspirational/unwired knobs.

### What goes where

| File | Holds | Committed? |
|---|---|---|
| `common.yaml` | `claude.betaHeader`/`anthropicVersion`, `a2a.server.{agentCard,path}`, `confirmation.{allow,deny}` | ✅ |
| `env/<env>.yaml` | `claude.{agentId,environmentId,agentVersion?}`, `a2a.server.listener.{host,port}`, `confirmation.default` | local ✅ / prod ❌ (`.example` ✅) |
| `secure/<env>.yaml` | `claude.apiKey` (as `![…]` or a placeholder) | local ✅ (placeholder) / prod ❌ (`.example` ✅) |

`a2a.server.agentCard` is the **filesystem path** to the A2A AgentCard document (default
`${app.home}/agent-card.json`). `agent-card.json` ships in `src/main/resources` and is extracted to
the app home at deploy time; point the key at another absolute path to serve a different card. (The
connector's `<a2a:agent-card file>` takes a real path, not a `classpath://` URL.)

## The environment toggle

`env` selects which `env/` and `secure/` file load. It defaults to `local` (the `global-property`),
so a fresh clone boots with no extra flags. Switch environments at deploy time:

```bash
# Studio:  Run config > Arguments > VM
# CLI / wrapper.conf additional.NNN
-M-Denv=prod
```

System properties win over the `global-property`, so `-M-Denv=prod` overrides the `local` default.

### Standing up a new environment

```bash
cp src/main/resources/config/env/prod.yaml.example    src/main/resources/config/env/prod.yaml
cp src/main/resources/config/secure/prod.yaml.example  src/main/resources/config/secure/prod.yaml
# edit both: real agentId/environmentId/port, and the encrypted apiKey (below)
# build, then deploy with:  -M-Denv=prod -M-Dsecure.key=<your-key>
```

> The config files are packaged **inside** the application jar, so changing `env/secure` values means
> a rebuild. That's fine for this POC; to flip envs without rebuilding, externalize the files (place
> them under the runtime `conf/` and point `file=` at an absolute path) — out of scope here.

## Securing the API key

`claude.apiKey` is resolved with a fallback so both a quick local run and a hardened prod deploy work
from the same code (`claude-headers` in `claude-client.xml`):

```dataweave
'x-api-key': (p('claude.apiKey') default p('secure::claude.apiKey'))
```

1. **`p('claude.apiKey')`** — a *plain* runtime property. If you pass `-M-Dclaude.apiKey=sk-ant-…`
   (or set it in `wrapper.conf`), it wins. This is the zero-friction local path; nothing secret is
   committed. `claude.apiKey` is also listed in `mule-artifact.json` `secureProperties`, so Runtime
   Manager masks it in the UI.
2. **`p('secure::claude.apiKey')`** — read from `config/secure/<env>.yaml` via the Secure
   Configuration Properties module. Plain values pass through untouched; `![…]` tokens are
   AES/CBC-decrypted with `${secure.key}`. Use this for prod so the key is never in plaintext —
   on disk or on a command line.

Because of the short-circuit `default`, the committed `secure/local.yaml` can carry a harmless
placeholder and the real local key is injected with `-D`.

### Encrypting a value

Download the **`secure-properties-tool-j17.jar`** (MuleSoft Secure Properties Tool, Java 17 build)
and run — matching the module's `algorithm="AES" mode="CBC"`:

```bash
java -cp secure-properties-tool-j17.jar com.mulesoft.tools.SecurePropertiesTool \
     string encrypt AES CBC <your-secure.key> "sk-ant-...your-real-key..."
# -> prints the ciphertext; paste it INSIDE the ![ ] token:
```

```yaml
# config/secure/prod.yaml
claude:
  apiKey: "![Vh1k…printed…ciphertext…==]"
```

Then deploy with the matching key: `-M-Denv=prod -M-Dsecure.key=<your-secure.key>`.

- Key length must fit the algorithm — **AES-128 needs a 16-character key** (e.g. the dev default
  `devdevdevdev1234`). Use a strong, secret key in prod and supply it only at runtime.
- Algorithms: `AES` (default), `Blowfish`, `DES`, `DESede`, `RC2`, `RCA`. Modes: `CBC` (default),
  `CFB`, `ECB`, `OFB`. If you encrypt with `--use-random-iv`, set `useRandomIVs="true"` on
  `<secure-properties:encrypt>` to match.

## Secrets hygiene

- **Never commit** `config/env/prod.yaml`, `config/secure/prod.yaml`, real API keys, or a real
  `secure.key`. They're gitignored; only the `.example` templates and the non-secret local defaults
  are tracked.
- The committed `secure/local.yaml` and `secure.key` default exist purely so local dev boots; treat
  the dev key as public and never reuse it for a real secret.
