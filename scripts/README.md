# scripts/

Developer & test helpers for the Claude A2A wrapper. **These are not part of the Mule application**
(they're deliberately kept out of `claude-a2a-adapter/` so the project imports cleanly into Anypoint
Studio and packages without stray files). Each script ships in **PowerShell (`.ps1`)** and **bash (`.sh`)** -
use PowerShell 5.1+ on Windows, or bash + `curl` + `jq` on macOS/Linux; `webhook-receiver.py` needs Python 3.

## Local dev loop (no Anypoint Studio)
The build → hot-deploy → wait-until-ready dev loop is provided by the **[`mule-headless-dev`](https://github.com/chirstius/mule-headless-dev)** Claude
skill (`setup` / `start` / `redeploy` / `restart` / `stop`). Run those to stand up and refresh the
runtime, then use the harnesses below to exercise it.

## Test harnesses (run against a deployed server, default `http://localhost:8081/a2a`)

| Script | Exercises |
|---|---|
| `local-test.ps1` | Agent card fetch + a blocking `message/send`. |
| `multiturn-test.ps1` | Two turns on one `contextId` (conversation memory). |
| `stream-test.ps1` | `message/stream` SSE relay (status-update / artifact-update). |
| `confirm-test.ps1` | HITL `input-required` round-trip, blocking (`-Decision allow|deny`). |
| `confirm-stream-test.ps1` | HITL `input-required` over streaming. |
| `cancel-probe.ps1` | `tasks/cancel` → `user.interrupt` against a running streaming task. |
| `webhook-receiver.py` | A local sink (port 9999) for push-notification delivery testing. |

The HITL scripts require the wrapper pointed at an `always_ask` agent (see `docs/CONFIG.md` /
`config/env/<env>.yaml`). See `docs/USAGE.md` for the A2A request shapes these scripts send.
