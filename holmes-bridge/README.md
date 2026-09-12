# holmes-bridge

A small Go service that presents [HolmesGPT](https://github.com/robusta-dev/holmesgpt)
as an **OpenAI-compatible chat model**, so Open WebUI (or any OpenAI client)
can drive it. It also keeps a **SQLite** record of every conversation, request
and tool call.

```
Open WebUI ──OpenAI /v1/chat/completions──▶ holmes-bridge ──/api/chat (SSE)──▶ HolmesGPT
                                                │
                                                └── SQLite (/data/holmes-bridge.db)
```

## What it does

* `GET /v1/models` lists one model, `holmesgpt`.
* `POST /v1/chat/completions` (streaming or not) forwards the latest user
  message to HolmesGPT and streams the investigation back as markdown that
  Open WebUI renders natively:
  * `<details type="reasoning">` blocks for the model's reasoning between steps,
  * `<details type="tool_calls">` blocks for every tool HolmesGPT ran, labelled
    `<tool> (<toolset>): <description>`, with arguments and (truncated) output,
  * the final analysis as plain markdown. `![caption](tool-image://<id>)`
    references (HolmesGPT's own UI convention, which Open WebUI would render
    as its logo) are replaced with the tool's image as a data URI when the
    tool returned one (Grafana renders), or with just the caption otherwise.
* **Conversation memory.** Open WebUI sends the whole chat every time. The
  bridge instead keeps HolmesGPT's own `conversation_history` per chat, which
  includes every tool call and result, and resumes from it. Follow-up
  questions therefore reuse what Holmes already found instead of re-running
  the investigation. Regenerating or editing an earlier message truncates the
  stored history back to that turn.
* **Audit trail.** Read-only JSON endpoints over the database:

  | Endpoint | Returns |
  |---|---|
  | `GET /` | service info and counts |
  | `GET /api/conversations` | chats, newest first |
  | `GET /api/conversations/{id}?history=true` | one chat, its requests, and (optionally) the raw HolmesGPT history |
  | `GET /api/requests?conversation_id=&limit=` | requests with status, tokens, cost, duration |
  | `GET /api/requests/{id}/tool_calls` | every tool call of a request, with full output |

The chat id comes from the `X-OpenWebUI-Chat-Id` header, which Open WebUI
sends when `ENABLE_FORWARD_USER_INFO_HEADERS=True`. Without it, the bridge
falls back to a hash of the user id and the first message.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `HOLMES_URL` | `http://localhost:5050` | HolmesGPT API base URL |
| `LISTEN_ADDR` | `:8000` | listen address |
| `DB_PATH` | `/data/holmes-bridge.db` | SQLite file (WAL mode) |
| `MODEL_ID` / `MODEL_NAME` | `holmesgpt` / `HolmesGPT` | model id and display name |
| `BRIDGE_API_KEY` | *(unset: accept any)* | require this bearer token on `/v1/*` |
| `TOOL_RESULT_MAX_CHARS` | `6000` | tool output shown in the chat (the full output is stored) |
| `HIDDEN_TOOLS` | `TodoWrite` | comma-separated tool names recorded in SQLite but not shown in the chat |
| `BRIDGE_SYSTEM_PROMPT` | *(built in)* | text appended to HolmesGPT's system prompt on every request; `none` sends nothing. The default tells Holmes it is talking to Open WebUI: prefer dedicated/MCP tools, name the tool behind each finding, and do not embed Prometheus results as images |
| `HOLMES_TIMEOUT` | `20m` | per-request deadline for a HolmesGPT investigation |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## Development

There is no Go toolchain requirement on the host: the demo builds the image on
the minikube node (`scripts/75-openwebui.sh`). To run tests locally with podman:

```bash
podman run --rm -v "$PWD":/src -w /src docker.io/library/golang:1.25-alpine \
  sh -c 'go vet ./... && go test ./...'
```

The SQLite driver is `modernc.org/sqlite` (pure Go), so the binary is static
and the runtime image is distroless.
