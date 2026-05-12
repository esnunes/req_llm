---
title: "feat: Add :claude_agent provider backed by the Claude Code CLI"
type: feat
status: active
created: 2026-05-12
deepened: 2026-05-12
depth: deep
---

# feat: Add `:claude_agent` provider backed by the Claude Code CLI

## Summary

Add a new ReqLLM provider, `:claude_agent`, that consumes Anthropic Claude through the locally installed Claude Code CLI (`claude` binary) instead of the HTTP `/v1/messages` endpoint. The provider lets callers spend their Claude subscription plan (Pro / Max / Team) in place of pay-per-token API credits, while keeping every public ReqLLM entry point — `generate_text/3`, `stream_text/3`, tool calling, `generate_object/4` — behaviorally indistinguishable from any other provider.

The change is **strictly additive**. The existing `:anthropic` HTTP provider and its `with_claude_subscription` OAuth path are untouched: no shared modules are rewritten, no env-driven fallback is introduced, and no public API of `:anthropic` is mutated. The new provider:

- Reuses the existing Anthropic model catalog under the new id (`claude_agent:claude-sonnet-4-5-20250929` etc.) — model ids are forwarded to the CLI via `--model`.
- Talks to the CLI via an Erlang `Port` running `claude --print --input-format stream-json --output-format stream-json --verbose [--include-partial-messages] --model <id> [--resume <id>] [--allowedTools …] [--disallowedTools …]`.
- Plugs into ReqLLM's request machinery via a **custom Req adapter** for non-streaming calls and a **new StreamServer transport** (alongside `Streaming.FinchClient` and `Streaming.WebSocketClient`) for streaming calls. From the rest of ReqLLM's perspective — telemetry, error wrapping, `Context`, `Response`, `StreamResponse`, `StreamChunk`, fixture step, usage step — this provider looks like any other.
- Owns the tool loop end-to-end: emits user-defined `ReqLLM.Tool` specs to Claude Code, dispatches `tool_use` events to Elixir callbacks, writes the matching `tool_result` back into the port's stdin, and reuses the existing Anthropic-style event decoder (`ReqLLM.Providers.Anthropic.Response.decode_stream_event/3`) for the `stream_event` wrapper events the CLI emits — these wrap the same content-block deltas the HTTP API would emit.
- Parses usage from the CLI's terminal `result` event and runs the existing pricing pipeline against the Anthropic registry entry, so cost figures stay comparable even though the subscription isn't actually metered per token.

The CLI is the provider's transport boundary. Anything that crosses that boundary — auth failure, missing binary, schema drift, port crash, caller cancellation — surfaces as a typed `ReqLLM.Error.*` with `stderr` content preserved when available. There is no silent fallback to the HTTP API.

---

## Problem Frame

ReqLLM today only reaches Anthropic through the HTTP API: requests cost API credits (or in the case of `with_claude_subscription`, draw against a user's subscription via an OAuth flow that ReqLLM doesn't fully manage). Many users already have an active Claude subscription and a locally authenticated `claude` CLI; they want to drive a ReqLLM call against that subscription without paying the per-token API rate or threading OAuth themselves.

The Claude Code CLI exposes a non-interactive bidirectional protocol (`--print --input-format stream-json --output-format stream-json`) that emits the same content-block deltas and tool-use events as the HTTP API, plus session metadata and aggregate usage. That protocol is rich enough to support every ReqLLM operation already exposed for text models. The only missing piece is a ReqLLM provider that speaks it.

This plan adds that provider as a new transport-layer adapter, not as a fork of `:anthropic`. The user's API surface (`ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", "Hello")`) is identical to every other provider; the difference is entirely below the provider boundary.

### Out of scope for v1

- Image generation, speech, transcription, OCR, embeddings, rerank — the CLI does not expose any of these.
- Bootstrapping or managing `claude login`. The plan assumes the binary is on `$PATH` and `claude auth` has already been run on the host.
- Auto-detection / fallback between HTTP and CLI transports based on env vars.
- Sharing CLI sessions across concurrent ReqLLM calls. Each call spawns its own Port; session reuse is explicit via the `:session_id` option.
- Native `--json-schema` structured output. The CLI does support this flag, but per the requirements `generate_object/4` is implemented on top of `generate_text` + tool-output-as-JSON, the same way other providers without native structured output do it. The flag is logged as a follow-up.

---

## Output Structure

The plan creates a new provider directory and a couple of new test/support files. The expected tree:

```
lib/req_llm/providers/
├── claude_agent.ex                     # U1 — provider module (use ReqLLM.Provider)
└── claude_agent/
    ├── cli.ex                          # U2 — Port lifecycle, flag building, stderr capture
    ├── protocol.ex                     # U2/U3 — stream-json event parsing + framing
    ├── req_adapter.ex                  # U2 — custom Req adapter for non-streaming
    ├── stream_client.ex                # U3 — StreamServer transport (Port → http_event)
    ├── tools.ex                        # U4 — tool advertisement + tool_use/tool_result loop
    └── usage.ex                        # U6 — terminal result → ReqLLM usage map

lib/req_llm/streaming/
└── (existing)                          # touched only to route :claude_agent to PortClient

test/support/
├── claude_agent_cli.exs                # U8 — escript fake binary (deterministic replay)
└── claude_agent_fixtures/               # U8 — JSON-line fixtures consumed by the fake binary
    ├── basic_text.jsonl
    ├── streaming_text.jsonl
    ├── tool_round_trip.jsonl
    ├── tool_error.jsonl
    ├── auth_failure.jsonl
    └── version_mismatch.jsonl

test/provider/claude_agent/
├── option_validation_test.exs           # U1, U5
├── cli_invocation_test.exs              # U2
├── stream_decode_test.exs               # U3
├── tools_test.exs                       # U4
├── usage_test.exs                       # U6
├── object_test.exs                      # U7
└── errors_test.exs                      # U2, U3 — failure paths

test/coverage/claude_agent/
└── live_test.exs                        # U8 — @tag :live, gated on REQ_CLAUDE_AGENT_LIVE=1

guides/
└── claude-agent-provider.md             # U9 — user-facing guide (auth, version pinning, limits)
```

The implementer may collapse `cli.ex` / `protocol.ex` / `stream_client.ex` into fewer modules if implementation reveals a simpler factoring — the per-unit `**Files:**` lists are authoritative for what each unit must produce, not this tree.

---

## High-Level Technical Design

> This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.

### Pipeline placement

The new provider plugs into both halves of the existing pipeline. For non-streaming calls, `prepare_request/4` builds a real `Req.Request` whose `:adapter` option is set to a custom adapter that translates the request into a port invocation. For streaming calls, the provider's `attach_stream/4` is not the right seam (it returns a `Finch.Request`); instead a new transport branch is added to `ReqLLM.StreamServer`'s existing transport dispatch (which already routes between `FinchClient` and `WebSocketClient`), and `:claude_agent` selects the new `PortClient` transport.

```
ReqLLM.generate_text("claude_agent:…", prompt, opts)
  └─> Generation.execute_generate_text/6
       └─> ClaudeAgent.prepare_request(:chat, model, ctx, opts)
            └─> Req.Request with :adapter = &ClaudeAgent.ReqAdapter.run/1
       └─> Req.request(req)
            └─> ReqAdapter.run/1
                 └─> CLI.invoke_sync(model, ctx, opts)         # Port open + write + read-to-result
                      ├─> stdout: line-delimited stream-json events
                      ├─> stderr: captured into error context
                      └─> exit: closed Port; surfaces as %Req.Response{status, body}
            └─> Anthropic.Response.decode_response equivalent
                 (synthetic response body mimics /v1/messages JSON)

ReqLLM.stream_text("claude_agent:…", prompt, opts)
  └─> Generation.stream_text → StreamServer.start_link + start_http
       └─> StreamServer.handle_call({:start_http, …})
            ├─> Keyword.get(opts, :stream_transport) ||
            │   provider_default_transport(provider_mod)        ← new dispatch hook
            └─> ClaudeAgent.StreamClient.start_stream/6
                 ├─> Port.open spawn_executable claude … --include-partial-messages
                 ├─> Task: stdout reader → StreamServer.http_event({:data, line})
                 ├─> Task: stderr reader → accumulates for error context
                 ├─> stdin writer: tool_result replies during tool loop
                 └─> on terminal result event → StreamServer.http_event(:done)
```

### Stream-json protocol model

The CLI emits one JSON object per line over stdout. Observed event shapes that the provider must handle (verified against `claude --version 2.1.119`):

| Event type | Source | Provider response |
|---|---|---|
| `{"type":"system","subtype":"init", …, "session_id":"…", "model":"…", "tools":[…], "mcp_servers":[{"name":"…","status":"connected\|failed\|needs-auth"}], "apiKeySource":"none\|env\|…"}` | Per session | Capture `session_id` into stream metadata. **Inspect `mcp_servers[].status`** — any `"failed"` entry for a server we registered (U4) means user-defined tools won't be reachable; surface as `ReqLLM.Error.API.Request` (status 502) before the model emits anything. `apiKeySource: "none"` confirms subscription auth; other values trigger a warning in metadata but don't fail the request |
| `{"type":"system","subtype":"status", "status":"requesting\|…"}` | Status pings | Ignore (informational); never emit a `StreamChunk` from these |
| `{"type":"rate_limit_event", "rate_limit_info":{"status":"allowed\|throttled","resetsAt":…,"rateLimitType":"five_hour","overageStatus":…}}` | Per turn | Surface into stream metadata under `:rate_limit` (last value wins). If `status != "allowed"`, emit a `StreamChunk.meta(%{rate_limit_warning: …})` so consumers see it before any tokens flow |
| `{"type":"stream_event","event":{"type":"message_start", …, "ttft_ms":…}}` | Token-level (only with `--include-partial-messages`) | Forward `event` payload to `Anthropic.Response.decode_stream_event/3`. The CLI adds `ttft_ms` which the Anthropic decoder ignores; that's safe |
| `{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text\|thinking\|tool_use","…":…}}}` | Token-level | Same — the decoder handles `text`, `thinking`, and `tool_use` block types correctly (verified: `lib/req_llm/providers/anthropic/response.ex`). **`thinking` blocks must be preserved through to U7** so the tool input extractor knows the model thought before calling the tool |
| `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta\|thinking_delta\|input_json_delta","…":…}}}` | Token-level | Same → emits `StreamChunk.text(...)`, `StreamChunk.thinking(...)`, or partial tool input deltas as appropriate |
| `{"type":"stream_event","event":{"type":"content_block_stop","index":…}}` | Token-level | Same — also the trigger for U4 to flush an accumulated `tool_use` block to the dispatcher |
| `{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":…}, "usage":{…}}}` | Per turn | Same — `stop_reason: "tool_use"` is the signal that the CLI is waiting for a `tool_result` event on stdin |
| `{"type":"stream_event","event":{"type":"message_stop"}}` | Per turn | Same; in a tool round-trip turn, **does not** mean the call is over (the CLI will emit a new `message_start` after we write the `tool_result`) |
| `{"type":"assistant","message":{…}}` | Full-message snapshot | Skip when `--include-partial-messages` is on (duplicate of stream deltas); use as the authoritative message when it is off (only path the non-streaming `generate_text` adapter sees) |
| `{"type":"user","message":{"role":"user","content":[{"type":"tool_result", …}]}}` | Echo of caller-injected tool result (only when `--replay-user-messages` is enabled — we don't set it in v1) | Ignore — included here for completeness in case the flag gets turned on for debugging |
| `{"type":"result","subtype":"success","is_error":false, …, "total_cost_usd":…, "usage":{…}, "modelUsage":{…}, "session_id":"…", "terminal_reason":"completed\|incomplete\|max_tokens\|cancelled", "permission_denials":[…]}` | Terminal | Build usage map; emit `:done`; complete `Response`/`StreamResponse`. **`permission_denials` non-empty** means the model tried to use a built-in tool that `--allowedTools`/`--disallowedTools` blocked — surface under `response.metadata[:permission_denials]` so the caller knows |
| `{"type":"result","subtype":"error","is_error":true, "error":…}` | Terminal-error | Wrap into `ReqLLM.Error.API.Response` with status synthesized from `terminal_reason` |

Tool round-trip (caller-side):

```
                 [CLI stdout]                                     [Elixir]
  stream_event{content_block_start, content_block: {type:"tool_use", id:"toolu_…", name:"…", input:{…}}}
   ... input_json_delta(s) ...
  stream_event{content_block_stop}
                                                               ──▶ Tools.dispatch(id, name, partial_input)
                                                                   • locates ReqLLM.Tool by name
                                                                   • applies callback
                                                                   • encodes result OR error
                 [CLI stdin]
  {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_…","content":[{"type":"text","text":"<result>"}],"is_error":false}]}}
```

The provider does **not** advertise user-defined tools by writing extra stream-json events. The CLI does not expose a stream-json-level "register tool" mechanism; the only declarative tool surfaces are `--mcp-config` (advertise tools by mounting an MCP stdio server) and the built-in tool gates `--allowedTools` / `--disallowedTools`. v1 advertises user tools by spinning up a small **in-process MCP stdio sidecar** (Phase 2 question Q1 documents the alternatives if implementation reveals a simpler mechanism). The sidecar's tool list is the user-defined `ReqLLM.Tool` specs; its `tools/call` handler dispatches to the Elixir callback. The MCP sidecar lives only for the duration of a single `claude` invocation and is torn down with the Port.

### Synthetic Req.Response shape

The non-streaming `ReqAdapter.run/1` returns `{:ok, %Req.Response{status: 200, body: <map>, headers: [...]}}` so the rest of the pipeline (Step.Error → Step.Retry → llm_decode_response → Step.Usage → Step.Telemetry → Step.Fixture) keeps working. The synthesized `body` is shaped like an Anthropic `/v1/messages` non-streaming response — `%{"id" => …, "type" => "message", "role" => "assistant", "content" => [...], "stop_reason" => …, "usage" => …}` — assembled by replaying the per-turn `stream_event` deltas through the same response builder the HTTP provider uses (`ReqLLM.Providers.Anthropic.Response`). This is the single biggest reuse lever in the plan and the reason no new response-decoding logic is needed for content blocks. Synthetic `status` reflects `terminal_reason` (`completed` → 200, anything else → mapped 4xx/5xx); synthetic `headers` carry the CLI version and session id for fixture/test inspection.

---

## Requirements

| ID | Requirement |
|---|---|
| R1 | New provider id `:claude_agent`, callable like any other (`ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", …)`) |
| R2 | Provider reuses the existing Anthropic model catalog — no new model definitions in `priv/`. Unknown / API-only models surface a clear error if their CLI counterpart isn't recognized |
| R3 | `generate_text/3` works end-to-end against the CLI |
| R4 | `stream_text/3` produces the same `StreamChunk` shapes any other provider produces, including per-token text deltas |
| R5 | User-defined `ReqLLM.Tool` specs participate in the CLI's tool loop: tool_use → callback → tool_result → continuation, multi-turn |
| R6 | `:allowed_tools` provider option toggles which Claude Code built-in tools (Read, Bash, Write, WebFetch, …) the CLI is allowed to invoke |
| R7 | `:session_id` (and the OpenAI-style `:previous_response_id` alias where it fits) maps to `--resume` so callers can extend a prior CLI session |
| R8 | `Usage` is populated from the CLI's terminal `result.usage`; cost is computed using the existing Anthropic pricing entry for the model |
| R9 | Missing `claude` binary surfaces as a typed `ReqLLM.Error.*` at request time — never a raw port crash, never silent fallback |
| R10 | Failed `claude auth` (or any 4xx-style CLI error) surfaces as a typed `ReqLLM.Error.*` with stderr content preserved |
| R11 | CLI version below a documented minimum (detected via `claude --version`) raises a typed error with the actionable upgrade message |
| R12 | Each call spawns its own Port; success, error, timeout, and caller cancellation all close the Port — no leaked processes |
| R13 | Any non-stream-json output on stdout is treated as a protocol error and surfaces with stderr content for diagnostics |
| R14 | `generate_object/4` works against a Zoi/JSON schema using the existing tool-output-as-JSON pattern |
| R15 | The existing `:anthropic` provider's public behavior is unchanged (no edits to `lib/req_llm/providers/anthropic.ex` semantics, no edits to its OAuth or `with_claude_subscription` path) |
| R16 | Tests run green without a real `claude` login; live tests are gated behind both a tag (`@tag :live`) and an env flag (`REQ_CLAUDE_AGENT_LIVE=1`) |
| R17 | Deliverable lands on the user's fork, not as a PR against `agentjido/req_llm` upstream |

---

## Scope Boundaries

### In scope

- New provider module `ReqLLM.Providers.ClaudeAgent` and its `lib/req_llm/providers/claude_agent/*.ex` support modules
- Custom Req adapter (`ClaudeAgent.ReqAdapter`) that proxies non-streaming calls through a Port
- New `StreamServer` transport (`ClaudeAgent.StreamClient`) that owns the Port for streaming calls
- One small dispatch hook in `ReqLLM.StreamServer.handle_call({:start_http, …})` so `:claude_agent` selects `PortClient` without changing the `:websocket` / default branches
- Stream-json event parsing + framing, plus reuse of `Anthropic.Response.decode_stream_event/3` for content-block deltas
- MCP stdio sidecar (in-process) for advertising user-defined tools; `--mcp-config` JSON written to a temp file and cleaned up
- Tool round-trip: dispatch `tool_use` to Elixir callback, encode result (including `is_error: true` on raised exceptions), write back as a `user`/`tool_result` stream-json event
- Provider option schema: `:allowed_tools`, `:disallowed_tools`, `:session_id`, `:previous_response_id` (alias), `:claude_binary` (path override), `:cli_timeout`, `:cli_env` (escape hatch for env vars)
- Usage / cost extraction tied into the existing `Step.Usage` pipeline via `extract_usage/2`
- Fake `claude` escript under `test/support/` driven by JSON-line fixtures
- Unit tests for every option/encoding/decoding/error path
- Live test suite gated behind tag + env flag
- User-facing guide page (`guides/claude-agent-provider.md`) covering install, auth, version pinning, supported models, and limits
- README + CHANGELOG mentions

### Deferred to follow-up work

- Native `--json-schema` structured output (CLI does support it; current plan uses the tool-output-as-JSON path the requirements specify). Track as a follow-up that can replace U7 internals without changing the public `generate_object/4` shape.
- Shared sessions across concurrent ReqLLM calls (would require a session pool / GenServer registry — out of scope for v1, callers handle reuse via `:session_id`).
- Stream-level `tool_use` dispatch (right now the plan dispatches at `content_block_stop` once the tool input JSON is fully accumulated; streaming partial inputs to a callback before the tool call is complete is not useful for v1).
- Auto-detection / fallback to HTTP `:anthropic` when `claude` is missing.
- Wiring CLI hooks/MCP servers from the caller — only the *built-in* tools surface is exposed in v1.
- Coverage matrix integration (`mix mc`). The CLI's pricing semantics are not the same as the HTTP API's even though we reuse pricing, so live coverage rows would be misleading.

### Outside this product's identity

- Anything that touches the HTTP `:anthropic` provider's behavior, OAuth flow, headers, or model id translation.
- Anything that mutates the user's `claude` login state (no calls to `claude auth login`, no token rewriting, no settings file edits).
- Network policy: this provider never makes HTTP requests directly — every byte goes through the local CLI subprocess.

---

## Key Technical Decisions

### D1. Use a custom Req adapter for non-streaming, a new StreamServer transport for streaming

**Rationale.** The user's prompt frames this as "a custom Req adapter analogous to `ReqLLM.FinchRequestAdapter`," but `ReqLLM.FinchRequestAdapter` is a request-mutation hook, not a transport adapter. The real Req extension point is the `:adapter` option, which lets the provider replace the HTTP step entirely. Pointing `prepare_request/4` at a port-running adapter preserves every other pipeline step (`Step.Error`, `Step.Retry`, `Step.Usage`, `Step.Telemetry`, `Step.Fixture`) unchanged.

For streaming, `attach_stream/4` is the wrong seam because it must return a `Finch.Request`. The cleanest extension is the existing transport dispatch inside `StreamServer.handle_call({:start_http, …})` (`lib/req_llm/stream_server.ex:424`), which already chooses between `FinchClient` and `WebSocketClient` based on the `:stream_transport` opt. We add a third arm — `:port` (default for `:claude_agent`) — and a `PortClient` module mirroring the shape of `WebSocketClient`.

**Tradeoff.** This adds one branch to `StreamServer`. The alternative (build a fake HTTP/2 frame source on top of `attach_stream/4`) is much more invasive and pretends to be HTTP without actually being HTTP. Adding a transport seam is the right level of generalization.

### D2. Treat the CLI's `stream_event` payload as Anthropic SSE and reuse `Anthropic.Response.decode_stream_event/3`

**Rationale.** The CLI's `stream_event.event` payload is byte-identical (modulo a couple of fields like `ttft_ms`) to the events the HTTP `/v1/messages` endpoint emits in `text/event-stream` mode. The existing decoder produces correct `StreamChunk` structs from those events. Reusing it removes a whole class of decoding bugs and means content-block parsing has a single source of truth.

**Tradeoff.** We import a private-by-convention module from the `:anthropic` provider. This couples the two providers at the *decoder* level (read-only) without coupling them at the *behavior* level. If `Anthropic.Response.decode_stream_event/3` ever changes its event shape contract, both providers must update together — but that contract change would also break the HTTP provider's streaming, so they're already coupled in practice. The alternative (write a parallel decoder) doubles maintenance.

### D3. Advertise user-defined tools through an in-process MCP stdio sidecar, not through stream-json events

**Rationale.** The CLI has no stream-json-level tool-registration message. The only ways to expose Elixir-side tools to Claude Code are (a) `--mcp-config` pointing at a JSON config with an MCP stdio server, (b) `--mcp-config` pointing at an HTTP MCP server, (c) `--tools`/`--allowedTools` for built-ins only. Option (a) is the lightest: the provider starts a small MCP stdio server (a hand-rolled minimal MCP responder is enough — the protocol's `initialize` / `tools/list` / `tools/call` subset is small), writes a one-line MCP config to a temp file, passes that file via `--mcp-config --strict-mcp-config`, and tears it down after the call.

**Verified during deepening (CLI 2.1.119).** The probe `claude -p --input-format stream-json --output-format stream-json --mcp-config /tmp/test_mcp.json --strict-mcp-config …` accepts a JSON file of shape:

```json
{
  "mcpServers": {
    "req-llm-tools": {
      "type": "stdio",
      "command": "<beam-side wrapper executable>",
      "args": ["<sidecar-mode args…>"],
      "env": {"REQ_LLM_TOOL_SOCKET": "/tmp/req_llm_<uuid>.sock"}
    }
  }
}
```

The CLI's `system/init` event reports each server's connection status under `mcp_servers[].status` (`connected`, `failed`, `needs-auth`). U4 reads that field at the very first init event and fails fast with `ReqLLM.Error.API.Request` (synthetic status 502) if any server we registered came up `failed` — this prevents the call from silently proceeding without the user's tools advertised.

**Implementation shape (directional).** The sidecar can't be a long-running BEAM process because the CLI spawns the configured `command` as a separate OS process. Two viable subshapes:

1. **Wrapper escript that proxies to the BEAM.** A tiny escript is shipped under `priv/bin/`, configured as the MCP `command`. The escript reads MCP JSON-RPC from stdin and forwards each request over a Unix-domain socket (path passed via `env`) to the live BEAM process that owns the call. Tool dispatch happens BEAM-side; the response travels back over the socket and out the escript's stdout.
2. **Hand-rolled Elixir escript that compiles in the user's tool registry at start.** Simpler but breaks tool callbacks that close over the BEAM's runtime state.

**Decision: subshape 1** — keeps Elixir callbacks live and natural, at the cost of one Unix socket per call. Sockets are scoped to a `/tmp/req_llm_<uuid>.sock` path and unlinked in the `after` block alongside the temp `--mcp-config` file.

**Tradeoff.** This is more machinery than a raw stream-json round-trip would be, but it's the protocol the CLI actually speaks. The user's prompt described the tool flow as a stream-json round-trip; the implementation adjusts because the CLI doesn't expose that surface. The compensating wins are (a) MCP is a public, versioned protocol with downstream stability guarantees, (b) the same sidecar can later be repurposed if the user ever wants to expose ReqLLM tools to arbitrary MCP clients, (c) failure detection via `mcp_servers[].status` is precise and observable.

### D4. Pin a minimum supported `claude` CLI version and detect drift via `claude --version`

**Rationale.** The stream-json schema and flag names can shift between Claude Code releases. The provider runs `claude --version` once per session (cached for the lifetime of the BEAM node), parses the SemVer, compares against a pinned minimum (initial pin: `>= 2.1.119`, the version this plan was validated against), and raises a typed `ReqLLM.Error.Invalid.Capability` if older. The check is cheap (single subprocess call returning a single line in ~50ms) and short-circuits the entire request path before any port-streaming work begins.

**Tradeoff.** Pinning fast means the provider will refuse older CLIs that may still work for some flows. Pinning loose risks silent breakage. Pinning at the known-good version is the conservative choice; the version constant lives in module attributes and is bumped intentionally as the CLI evolves. Cache invalidation is by process lifetime — a CLI upgrade requires a BEAM restart, which matches how every other version pin in the project works (`@default_anthropic_version`).

### D5. Each call gets its own Port; session reuse is explicit via `:session_id`

**Rationale.** Concurrency is simpler when there's no shared state. A long-lived CLI session would force ownership negotiation (which BEAM process owns the Port?), force serialization (the CLI's stream-json protocol is one turn at a time), and complicate cancellation. Spawning per call mirrors the `Finch` per-request model everywhere else in ReqLLM. Session continuity is opt-in: `:session_id` translates to `--resume <id>` and the CLI rehydrates the prior conversation server-side.

**Tradeoff.** Per-call spawn pays a 1-3s startup cost per request (CLI bootstrap + cache warm-up). For latency-sensitive applications this would hurt. The followup plan to add a session pool can be built on top of `:session_id` without changing public APIs.

### D6. Fake `claude` escript for tests, real CLI behind a flag

**Rationale.** Contributors don't all have Claude subscriptions. A real-CLI dependency in `mix test` would break CI for half the project. The fake binary is a small Elixir escript that:

- Reads stream-json events from stdin
- Replays a scripted set of stream-json events from a fixture file (chosen via the first prompt's marker, or an `--fixture` flag in tests)
- Pauses appropriately to simulate the tool round-trip (waits for a `user`/`tool_result` event before emitting the next assistant block)
- Exits 0 on `result.success`, exits 1 on a scripted error fixture

Tests inject the fake binary path via the new `:claude_binary` provider option, so they never depend on a real Claude Code login. Live tests gate on `REQ_CLAUDE_AGENT_LIVE=1` *and* the `:live` tag, and use the real binary.

**Tradeoff.** The fake binary is one more thing to keep in sync with the real CLI's protocol. Mitigated by (a) keeping the fixtures small and well-named, (b) running the live suite in CI on a schedule against a controlled host, (c) the protocol model documented in this plan so future drift is visible.

### D7. `generate_object/4` uses tool-output-as-JSON, not `--json-schema`

**Rationale.** The user requirements explicitly call out the tool-output-as-JSON path. Implementing both the tool-strict and `--json-schema` paths doubles the surface for v1 testing without a behavior win — `generate_object/4` callers don't see the difference. The `--json-schema` flag is logged as a follow-up.

**Tradeoff.** Tool-output-as-JSON adds one extra round-trip (the model emits a tool_use, we run a no-op callback that returns the parsed JSON). That's the same shape `:anthropic` uses today in `:tool_strict` mode (`prepare_strict_tool_request/4` at `lib/req_llm/providers/anthropic.ex:310`), so the cost is well-understood and not a regression.

---

## Implementation Units

### U1. Scaffold the `:claude_agent` provider module and option schema

**Goal.** Stand up the provider module so `ReqLLM.provider(:claude_agent)` returns it, options validate, and the dispatch path knows the new id. No CLI interaction yet — this unit produces a provider that compiles, registers, validates options, and raises a "not implemented" error on actual generation calls.

**Requirements.** R1, R2, R6, R7, R15

**Dependencies.** None.

**Files.**
- `lib/req_llm/providers/claude_agent.ex` — provider module with `use ReqLLM.Provider, id: :claude_agent, default_base_url: "claude://local"`. The `default_base_url` is symbolic — there's no real URL — but the `use` macro requires one (`lib/req_llm/provider.ex:667`).
- `test/provider/claude_agent/option_validation_test.exs`

**Approach.**
- Define `@provider_schema` with: `:allowed_tools` (list-of-string or `:default` / `:none`), `:disallowed_tools` (list-of-string), `:session_id` (uuid string), `:previous_response_id` (uuid string, alias for session_id when both passed → reject), `:claude_binary` (path; default `System.find_executable("claude")`), `:cli_timeout` (ms; default 120_000), `:include_partial_messages` (boolean; default true when stream, false when not), `:permission_mode` (atom; default `:default`; passed through if supported).
- Implement `normalize_model_id/1` to translate `:claude_agent` model lookups to the existing `:anthropic` catalog. The model registry lookup pattern lives in `LLMDB`. The simplest path is for `normalize_model_id` to swap the provider id to `:anthropic` for catalog reads and re-stamp it to `:claude_agent` for the resulting struct.
- Implement `prepare_request/4` for `:chat` and `:object`, returning a `Req.Request` whose `:adapter` option points at `ClaudeAgent.ReqAdapter.run/1` (the adapter ships in U2 with a not-yet-implemented body that raises).
- Implement `attach/3` as a no-op (no auth header munging — CLI auth is out-of-process).
- Implement `default_env_key/0` to return `nil` (the provider has no env-driven secret).
- Reject `:operation` values other than `:chat` and `:object` with the existing `ReqLLM.Error.Invalid.Parameter` shape (see `lib/req_llm/providers/anthropic.ex:239` for the pattern).

**Patterns to follow.**
- `lib/req_llm/providers/anthropic.ex:1-180` for the `use ReqLLM.Provider` shape and `@provider_schema` style.
- `lib/req_llm/providers/openai_codex.ex:1-115` for `:session_id` / `:previous_response_id` option naming and the way it co-exists with provider-specific transport flags.
- AGENTS.md "Provider Architecture" section (`AGENTS.md:81-104`) for the callback contract.

**Test scenarios.**
- Happy path: `ReqLLM.provider(:claude_agent)` returns the module; `ReqLLM.Providers.list()` includes `:claude_agent`.
- Option validation: `:allowed_tools` accepts `["Read", "Bash"]`, `:default`, `:none`; rejects integers, maps, single binaries with a `ReqLLM.Error.Validation.Error`.
- Option validation: `:session_id` accepts a valid UUID, rejects non-UUID strings.
- Option validation: providing both `:session_id` and `:previous_response_id` raises a `ReqLLM.Error.Invalid.Parameter` (one is an alias for the other; both at once is ambiguous).
- Operation gating: `prepare_request(:embed, …)` returns `{:error, %ReqLLM.Error.Invalid.Parameter{}}` matching the Anthropic pattern.
- Model catalog: `ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")` returns a `%LLMDB.Model{}` with `provider: :claude_agent` and the same `cost`, `capabilities`, `id` fields as `ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")`.
- Model catalog: `ReqLLM.model("claude_agent:not-a-real-model")` returns `{:error, _}`.
- Test expectation for `attach/3`: round-trips the request unchanged when the model provider is `:claude_agent`; raises `ReqLLM.Error.Invalid.Provider` when the model's provider is anything else (mirror `anthropic.ex:341-344`).

**Verification.**
- `mix compile --warnings-as-errors` succeeds.
- `mix test test/provider/claude_agent/option_validation_test.exs` passes.
- `iex -S mix` and `ReqLLM.provider(:claude_agent)` returns the module.
- `mix credo --strict` is clean for the new files (the project's credo rule forbids comments in function bodies; see `AGENTS.md:112`).

---

### U2. Build the CLI subprocess layer and the synchronous Req adapter

**Goal.** Wire `generate_text/3` end-to-end through the CLI by implementing the Port lifecycle, the stream-json framer, and the custom Req adapter. After this unit, `ReqLLM.generate_text("claude_agent:…", "Hello")` works against the *fake* `claude` binary (the real one is exercised by the live suite added in U8).

**Requirements.** R1, R3, R9, R10, R11, R12, R13, R15

**Dependencies.** U1.

**Execution note.** Implement test-first: the fixture-driven fake binary makes a failing integration test cheap to write, and the Port lifecycle has subtle failure modes (zombie processes, partial reads at EOF) that are much easier to drive from a red test than to bolt onto a green one.

**Files.**
- `lib/req_llm/providers/claude_agent/cli.ex` — `open_port/3`, `write_event/2`, `read_to_terminal/2`, `close_port/1`, version detection (`claude --version` cache).
- `lib/req_llm/providers/claude_agent/protocol.ex` — line framing for stdout (handle partial lines across reads), JSON decoding, event-type tagging.
- `lib/req_llm/providers/claude_agent/req_adapter.ex` — `run(%Req.Request{}) :: {:ok, %Req.Response{}} | {:error, term()}`; orchestrates open → write initial user event → read-to-result → close.
- `test/provider/claude_agent/cli_invocation_test.exs`
- `test/provider/claude_agent/errors_test.exs` (introduced here; shared with U3)
- `test/support/claude_agent_cli.exs` — fake binary entry point (extended in U8; first version handles only the basic-text fixture so this unit can be tested end-to-end)
- `test/support/claude_agent_fixtures/basic_text.jsonl`
- `test/support/claude_agent_fixtures/auth_failure.jsonl`
- `test/support/claude_agent_fixtures/version_mismatch.jsonl`

**Approach.**
- **Port + per-line stream-json demux (resolved during deepening).** Use `Port.open({:spawn_executable, binary}, [:binary, :exit_status, :hide, :stderr_to_stdout, args: cli_args])`. Both streams arrive on the same port; we line-split incoming bytes, then classify each line:
  - Line parses as JSON with a known `type` field (`system`, `assistant`, `user`, `stream_event`, `rate_limit_event`, `result`) → forward to the stream-json handler.
  - Line fails to parse OR parses to JSON without a recognized `type` → append to a per-call `diagnostic_buffer` (size-capped at 64KB; older bytes are dropped with a flag so the error message can say "stderr truncated").
  - Empty line → skip.
  This trades a small ambiguity (CLI could in principle emit a stderr line that happens to be valid stream-json — observed never to happen across the protocol probes for this plan) for not shipping a wrapper script, not adding `erlexec` as a dep, and not depending on platform-specific FIFO behavior. The classifier is the single source of truth for "is this a protocol event or diagnostic noise."
- **Rejected alternatives** (recorded for posterity, since they were live options during the first pass):
  - `System.cmd/3` with `:input` — buffered stdin, no interactive tool round-trip; usable for one-shot calls without tools but breaks U4 entirely. Not worth two code paths.
  - Wrapper shell script under `priv/bin/` doing `2>>tmpfile` — adds an OS dependency (shell semantics differ on Windows), adds a temp-file lifecycle, gives nothing back over per-line demux.
  - `:exec` / `erlexec` package — would split streams cleanly, but adding a runtime dep for a single subprocess flow is the wrong tradeoff. Out of scope.
- **stdin writes:** `Port.command(port, line <> "\n")` for each outgoing stream-json event (initial user event, subsequent tool_result events). The CLI consumes one JSON object per line and is line-buffered.
- **Lifecycle:** Spawn → write initial user event → read loop dispatched on `{port, {:data, chunk}}` and `{port, {:exit_status, n}}` messages → on `result` event or terminal exit, run `Port.close(port)` (idempotent — closing an already-closed port is a no-op) and reap any lingering message in the mailbox. `Process.flag(:trap_exit, true)` is **not** set on the calling process for the non-streaming path; instead the `Port.close` + selective receive pattern is enough because `:spawn_executable` ports send `{:exit_status, _}` automatically.
- **Cancellation:** Caller-side timeout (`:cli_timeout`) fires a `Process.send_after(self(), :cli_timeout, ms)`. On firing, run `Port.close(port)`, drain pending port messages, return `{:error, %ReqLLM.Error.API.Request{reason: :timeout, …}}`. Caller process cancellation (caller killed mid-call) — since the port is owned by the calling process and `:spawn_executable` ports get a SIGTERM when the BEAM port owner dies, the OS process is reaped automatically; the U2 cleanup test scenario verifies this is actually happening.
- **Version detection:** Cache `claude --version` output in `:persistent_term` keyed by binary path. Pin minimum to `2.1.119` (the version validated for this plan). The version check is invoked lazily on the first request through the provider; subsequent requests hit the cache. Cache invalidation: BEAM restart, or explicit `ReqLLM.Providers.ClaudeAgent.CLI.invalidate_version_cache!/0` for power users on a CI host doing rolling upgrades.
- Build CLI args: `["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", model_id]` plus optional `--resume`, `--allowedTools`, `--disallowedTools`, `--permission-mode`. **`--verbose` is required because `--print` + `--output-format=stream-json` errors out without it** — discovered during protocol validation.
- Write initial user event: `%{"type" => "user", "message" => %{"role" => "user", "content" => extract_text_or_blocks(context)}}` as a single line + `\n`.
- Read loop: `receive do {port, {:data, chunk}} -> ...` accumulates bytes, splits on `\n`, JSON-decodes each line, dispatches by `event.type`. On `{:exit_status, n}`, finalize: if a `result` event was seen, return synthesized `%Req.Response{}`; otherwise raise `ReqLLM.Error.API.Response` carrying captured stderr.
- Synthesized response shape: see "Synthetic Req.Response shape" in the technical design. The Response builder reuses `Anthropic.Response.decode_stream_event/3` against the accumulated `stream_event` payloads, then renders the final accumulated message via the existing Anthropic non-streaming response shape.
- **Init-event `apiKeySource` observability.** Capture the value (`"none" | "env" | "settings" | …`) into stream metadata under `:cli_api_key_source`. Subscription users see `"none"`; if a caller expected subscription-only and the value is something else, they have a clear diagnostic. v1 does *not* fail on a mismatch — `claude` is the auth boundary and the user has already opted into whatever they configured — but the observable surface lets callers add their own assertions.
- Cancellation: caller-side timeout (`:cli_timeout`) sends an exit signal to the port; the adapter returns `{:error, %ReqLLM.Error.API.Request{reason: :timeout, …}}`. Catch-all `after` block sends `Port.close/1` to guarantee cleanup.

**Patterns to follow.**
- `lib/req_llm/providers/anthropic/response.ex` for response decoding (called as a library, not re-implemented).
- `lib/req_llm/streaming/finch_client.ex:60-100` for the "build a streaming context, hand it to a task" framing (the U2 adapter is single-call rather than streaming, but the shape is similar).
- `lib/req_llm/step/error.ex` for how the request pipeline expects errors to surface.

**Technical design (directional).**

```
ReqAdapter.run(%Req.Request{} = req) do
  cli_args     = CLI.build_args(req)               # model, allowedTools, resume, …
  binary       = CLI.resolve_binary(req)           # raises Invalid.Capability if missing/old
  user_event   = Protocol.encode_user_event(req)   # initial prompt as stream-json
  port         = CLI.open_port(binary, cli_args)
  CLI.write_event(port, user_event)
  case CLI.read_to_terminal(port, req.options.cli_timeout) do
    {:ok, %{result: result, events: events, session_id: sid}} ->
      body    = Protocol.synthesize_response_body(events, result)
      headers = [{"x-claude-agent-session-id", sid}, {"x-claude-cli-version", CLI.version()}]
      {req, %Req.Response{status: status_for(result), headers: headers, body: body}}

    {:error, {:protocol_error, stderr}} ->
      {req, %ReqLLM.Error.API.Response{reason: "stream-json protocol error", response_body: stderr}}

    {:error, {:timeout, _}} ->
      {req, %ReqLLM.Error.API.Request{reason: :timeout, status: 504}}

    {:error, {:exit, code, stderr}} ->
      {req, error_for_exit(code, stderr)}            # auth → API.Request{status: 401}
  end
end
```

> Directional only — the implementer is free to refactor the data flow as long as the observable behavior (synthetic %Req.Response{} on success, typed %ReqLLM.Error.*{} on failure) is preserved.

**Test scenarios.**
- Happy path: fake CLI configured with `basic_text.jsonl` → `ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", "Hello")` returns `{:ok, %ReqLLM.Response{}}` with `response.text() =~ "Hi there"`.
- Happy path with options: `:allowed_tools => ["Read"]` appears in the captured CLI args (assert via fake binary's `argv` echo to a temp file).
- Happy path with session: `:session_id => "uuid"` → `--resume uuid` in argv; the assigned `session_id` from the init event is exposed on the response's metadata.
- Edge case — empty context: rejects with `Invalid.MessageList` before spawning the port (no zombie process).
- Edge case — large prompt (>100KB): writes succeed (Port handles backpressure); response decodes correctly.
- Error path — missing binary: `ReqLLM.generate_text` with `:claude_binary => "/no/such/path"` returns `{:error, %ReqLLM.Error.Invalid.Capability{}}` whose message mentions the path and the install hint.
- Error path — version drift: fake binary configured to print `1.5.0` for `--version` → returns `Invalid.Capability` with the required-version message.
- Error path — auth failure: fake binary writes the `auth_failure.jsonl` script then exits 1 → returns `%ReqLLM.Error.API.Request{status: 401, response_body: <stderr>}`.
- Error path — non-JSON line on stdout: fake binary emits `"this is not JSON\n"` interleaved with valid events → the non-JSON line lands in the diagnostic buffer, the valid events continue to flow, and if the call still ends successfully via a `result` event the diagnostic is exposed under `response.metadata[:diagnostic_buffer]`. If the call ends *without* a `result` event, the error returned to the caller carries the diagnostic buffer in `response_body` (this is the "auth failure" / "permission denied" surfacing path).
- Edge case — line that parses as JSON but has unknown `type`: same handling as "non-JSON line" — appended to diagnostic buffer; the protocol-error path triggers only on missing terminal `result` event.
- Edge case — diagnostic buffer overflow: fake binary emits >64KB of garbage → buffer is truncated at the cap; `response.metadata[:diagnostic_buffer_truncated]` is `true`.
- Error path — port crash mid-stream (fake binary `kill -9`s itself): returns `%ReqLLM.Error.API.Request{reason: ~r/port closed unexpectedly/}` with whatever stderr was captured.
- Error path — timeout: fake binary sleeps 5s, `:cli_timeout => 100` → returns `%ReqLLM.Error.API.Request{reason: :timeout}` within 200ms wall time; verify the port process is gone (`Process.alive?` on the port).
- Error path — caller cancellation: caller process killed mid-call → port process is reaped within 1s.
- Stderr surfacing: fake binary writes "ANTHROPIC_API_KEY not found\n" to stderr then exits 1 → error message includes that string.
- Cleanup: 100 sequential successful calls leave zero leaked OS processes (`pgrep -f claude_agent_cli` returns nothing).

**Verification.**
- `mix test test/provider/claude_agent/cli_invocation_test.exs test/provider/claude_agent/errors_test.exs` passes.
- `mix test --warnings-as-errors` is clean.
- `iex -S mix` against a fake-binary-configured app: `ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", "hi")` returns a Response in under 2s.

---

### U3. Streaming transport: a Port-owning client wired into `StreamServer`

**Goal.** Make `stream_text/3` work end-to-end against the CLI. The provider's streaming uses a new `ClaudeAgent.StreamClient` module that mirrors the `Streaming.WebSocketClient` shape and is selected by a one-line addition to `StreamServer`'s transport dispatch. Token-level deltas flow through `Anthropic.Response.decode_stream_event/3` into the existing `StreamChunk` queue, with full backpressure.

**Requirements.** R1, R4, R12, R13, R15

**Dependencies.** U2 (Port lifecycle, protocol parsing).

**Execution note.** Test-first for the StreamServer integration. The mock `MockProvider` in `test/support/stream_server_helpers.ex:14-65` and the existing `StreamServer` test patterns make it straightforward to drive `PortClient` with a deterministic event sequence and assert chunk-level behavior.

**Files.**
- `lib/req_llm/providers/claude_agent/stream_client.ex` — public surface `start_stream/6` matching `Streaming.WebSocketClient.start_stream/6`.
- `lib/req_llm/stream_server.ex` — extend the transport dispatch at `lib/req_llm/stream_server.ex:424-430` to route `:claude_agent` (or `:stream_transport => :port`) to the new client. Roughly:
  ```elixir
  streamer_mod =
    case Keyword.get(opts, :stream_transport) do
      :websocket -> ReqLLM.Streaming.WebSocketClient
      :port      -> ReqLLM.Providers.ClaudeAgent.StreamClient
      _          -> ReqLLM.Streaming.FinchClient
    end
  ```
  with `provider_default_transport(provider_mod, opts)` picking `:port` when `provider_mod == ReqLLM.Providers.ClaudeAgent`. The change is one branch + one helper; do not refactor the existing arms.
- `lib/req_llm/providers/claude_agent.ex` — implement `attach_stream/4` to return a sentinel value (or override the StreamServer dispatch entirely so `attach_stream` is never called for this provider; the cleanest approach is to gate dispatch on the provider, not have `attach_stream` lie about returning a `Finch.Request`).
- `test/provider/claude_agent/stream_decode_test.exs`
- `test/support/claude_agent_fixtures/streaming_text.jsonl`

**Approach.**
- `StreamClient.start_stream/6` is the integration point. It receives `(provider_mod, model, context, opts, stream_server_pid, _finch_name)` from `StreamServer.handle_call({:start_http, …})`, just like `WebSocketClient.start_stream/6` does.
- Inside, it spawns a task supervised by `ReqLLM.TaskSupervisor` that:
  1. Opens the Port with the same CLI args as U2, plus `--include-partial-messages` so we get token-level deltas (validated during protocol research — see High-Level Technical Design).
  2. Writes the initial `user` event.
  3. In a `receive` loop, splits stdout lines, JSON-decodes them, normalizes the `event` field (the CLI wraps Anthropic SSE events under `stream_event`), and forwards each to `StreamServer.http_event(server, {:data, line_with_anthropic_shape})`. The provider's `decode_stream_event/3` callback (set on the provider module) re-uses `Anthropic.Response.decode_stream_event/3` to produce `StreamChunk`s.
  4. On `result.success` → `StreamServer.http_event(server, :done)` and updates the StreamServer metadata with `total_cost_usd`, the final `usage`, and the `session_id`.
  5. On `result.error` → `StreamServer.http_event(server, {:error, %ReqLLM.Error.API.Stream{}})`.
- The task is linked to the StreamServer so when the server exits, the port closes. The Port is explicitly closed in the task's `after` block so any caller cancellation propagates.
- Backpressure: the stdout reader writes events into the StreamServer via `GenServer.call/2` (synchronous), so the existing `high_watermark` guard automatically rate-limits the reader. The Port has its own kernel buffer, so the CLI back-pressures naturally if the reader pauses long enough.
- Return shape: `{:ok, task_pid, http_context, canonical_json}` per the existing transport contract. `http_context` is `HTTPContext.new("claude://local", :post, %{"x-claude-cli-version" => CLI.version()})`. `canonical_json` is the synthesized request body so the fixture pipeline can capture it.

**Patterns to follow.**
- `lib/req_llm/streaming/web_socket_client.ex:1-125` for the overall task / lifecycle / http_context shape.
- `lib/req_llm/streaming/finch_client.ex:150-230` for the stdout chunk → `StreamServer.http_event` forwarding pattern (FinchClient does this for HTTP chunks; we do it for stdout lines).
- `test/support/stream_server_helpers.ex:14-65` for how to drive a StreamServer with synthetic events in tests.

**Test scenarios.**
- Happy path: fake binary configured with `streaming_text.jsonl` (a basic message split across 5 `content_block_delta` events) → `ReqLLM.stream_text` returns a `StreamResponse`; consuming the stream yields 5 `StreamChunk.text(...)` chunks with the text concatenated to the expected string.
- Happy path: `:include_partial_messages => false` → consumer sees a single `StreamChunk` from the `assistant` event (no per-token deltas), and `--include-partial-messages` is **not** in argv.
- Edge case — large response (1000+ events): no chunks dropped, no out-of-order delivery; final usage map populated.
- Edge case — backpressure: consumer sleeps for 5s between `next/2` calls; the reader's `GenServer.call/2` blocks (verify via instrumentation that no chunks are queued past `high_watermark`); no port crash.
- Error path — port crashes mid-stream: StreamServer's status transitions to `{:error, …}`; consumer's next `next/2` returns `{:error, _}`; port process is reaped.
- Error path — non-JSON line in the middle of valid events: stream errors with `ReqLLM.Error.API.Stream`; events received before the bad line are *not* delivered (transactional failure) — verify the consumer either gets all good chunks then the error, or only the error, but never a partial happy result.
- Error path — caller cancels mid-stream (`StreamServer.cancel/1`): port closes; the OS process is gone within 1s.
- Metadata: terminal `result` event populates `await_metadata/2` with `:usage`, `:cost`, `:session_id`, and the `total_cost_usd` value.
- Session resumption: `:session_id => "uuid"` makes `--resume uuid` appear in argv; the assigned session_id (from init) matches the one supplied.
- Transport dispatch: invoking `stream_text` with `claude_agent:…` routes to `StreamClient` (verify by spying via `Application.get_env` debug toggle or by asserting the http_context's URL is `claude://local`); invoking `stream_text` with `anthropic:…` still routes to `FinchClient` (regression).
- Concurrency: two concurrent `stream_text` calls each open their own port; both finish; neither's events leak into the other (assert by comparing session_ids).

**Verification.**
- `mix test test/provider/claude_agent/stream_decode_test.exs` passes.
- `mix test --only "provider:anthropic"` still passes (no regression in the HTTP provider's streaming path).
- `mix test --warnings-as-errors` is clean.

---

### U4. User-defined tools: MCP sidecar advertisement and tool_use round-trip

**Goal.** Enable `ReqLLM.Tool` specs to participate in the CLI's tool loop. When the model emits a `tool_use` content block, the provider runs the Elixir callback and writes back a `tool_result` event (as a `user` message) into the port's stdin. The loop continues until the CLI emits its terminal `result` event.

**Requirements.** R5, R10

**Dependencies.** U2 (Port + protocol), U3 (streaming path that observes `tool_use` content blocks).

**Files.**
- `lib/req_llm/providers/claude_agent/tools.ex` — `advertise/1` (writes MCP config JSON to a temp file, starts the in-process MCP stdio server), `dispatch/4` (callback → tool_result event), `teardown/1` (cleanup).
- `lib/req_llm/providers/claude_agent/cli.ex` — extend `build_args/1` to pass `--mcp-config <path>` and `--strict-mcp-config` when user tools are present.
- `lib/req_llm/providers/claude_agent/req_adapter.ex` & `stream_client.ex` — add the tool-loop branch: on a complete `tool_use` content block, dispatch and write the matching `tool_result`.
- `test/provider/claude_agent/tools_test.exs`
- `test/support/claude_agent_fixtures/tool_round_trip.jsonl` (single-turn tool call)
- `test/support/claude_agent_fixtures/tool_round_trip_multi.jsonl` (multi-turn)
- `test/support/claude_agent_fixtures/tool_error.jsonl` (callback raises / returns error)

**Approach.**
- **MCP sidecar = wrapper escript + BEAM-side dispatcher (per D3).** Per call:
  1. Generate a UUID; mint a socket path `/tmp/req_llm_<uuid>.sock` (Windows: `\\.\pipe\req_llm_<uuid>`).
  2. Start a `GenServer` (the BEAM-side dispatcher) that listens on the socket, holds the `ReqLLM.Tool` registry for this call, and runs `tools/call` against the matching callback when MCP requests arrive.
  3. Write a temp `--mcp-config` JSON file with one stdio server entry whose `command` is the shipped escript path (`priv/bin/req_llm_mcp_proxy`) and whose `env` carries the socket path.
  4. Spawn the CLI with `--mcp-config <tmpfile> --strict-mcp-config`. `--strict-mcp-config` ensures the user's home-directory MCP config does not bleed into the call.
  5. The escript subprocess is spawned by the CLI; it connects to the socket, the CLI then sends MCP `initialize` and `tools/list` to the escript over stdio, the escript proxies to the BEAM dispatcher, the dispatcher returns the user-defined tool list as JSON Schema (built from `ReqLLM.Tool` specs via `ReqLLM.Schema.to_json/1`).
- **Init validation.** As soon as the first `system/init` event arrives on the CLI's stdout, inspect `mcp_servers[].status` for our registered server (named `req-llm-tools`). On `"failed"`, immediately fail the request with `ReqLLM.Error.API.Request{reason: "MCP sidecar failed to advertise tools", status: 502, response_body: diagnostic_buffer}`. On `"needs-auth"`, same — sidecars we control should never need auth and that's a configuration bug. On `"connected"`, proceed. This check runs *before* the model is given a chance to act, so a misadvertised tool surface fails loud.
- **Tool dispatch (`tools/call`):**
  - Callback returns `{:ok, result}` → MCP response with the result encoded as a text content block (or JSON-stringified if non-binary); the CLI gives this to the model as the tool result.
  - Callback returns `{:error, reason}` → MCP response with `isError: true` and the reason in the content; the CLI passes this back as a `tool_result` with `is_error: true`; the user-facing ReqLLM call still completes successfully with the model's recovery turn.
  - Callback raises → caught, same shape as `{:error, reason}` with the Exception's `message/1`; the raised class+stacktrace recorded in `response.metadata[:tool_errors]`.
- **Stream-json loop coupling.** The U2/U3 adapters need a small extension: the loop's terminal predicate is the `result` event, not `message_stop`. When the model emits a `tool_use` content block, the CLI handles the round-trip *through the sidecar* — the BEAM-side adapter does NOT write a `tool_result` event on stdin (that path is the older HTTP-style flow and is not how MCP-advertised tools flow in this CLI). The adapter simply keeps reading until `result` arrives; tool execution happens out-of-band via the sidecar's `tools/call` handling. The `tool_result` stream-json event row in the protocol table is preserved only for completeness — we don't emit it.
- **Built-in tools (Read, Bash, etc.) are orthogonal:** those flow through `--allowedTools`/`--disallowedTools` and don't touch the MCP path. `:allowed_tools => :none` + no user tools → no `--mcp-config` flag at all (avoids the sidecar startup cost on tool-free calls). `:allowed_tools` and user-defined tools coexist freely.
- **Cleanup.** `after` block on every exit path: stop the dispatcher GenServer, delete the socket file, delete the temp `--mcp-config` file. Use `File.rm/1` (idempotent) so double-cleanup on retry doesn't error.

**Patterns to follow.**
- `lib/req_llm/tool.ex` for the `ReqLLM.Tool` callback contract.
- `lib/req_llm/providers/anthropic/context.ex:380-410` for the existing Anthropic tool-encoding shape (we'll convert our `ReqLLM.Tool` specs to the same JSON Schema shape, but expose them through MCP `tools/list` rather than via the `tools` field in the request body).

**Test scenarios.**
- Happy path (single-turn tool): user-defined `weather` tool, fake CLI replays `tool_round_trip.jsonl` (which mocks the *CLI*'s side of the protocol — assistant emits a `tool_use` block, then after a synthetic delay emits the recovery turn) and the test's MCP dispatcher is invoked via the real socket → assertion: the dispatcher's callback was invoked exactly once with the right args; the model's final text turn is in the response.
- Happy path (multi-turn): tool called twice with different args; final response reflects both results.
- Happy path (streaming): `stream_text/3` with a tool — consumer sees text chunks before and after the tool round-trip; the stream completes with one terminal `:done`.
- **MCP advertisement failure**: fake CLI emits `mcp_servers:[{name:"req-llm-tools", status:"failed"}]` in its init event → call fails fast with `ReqLLM.Error.API.Request{status: 502, reason: ~r/MCP sidecar/}` **before** any model tokens are emitted; the BEAM-side dispatcher is reaped within 1s of the error.
- **Sidecar process lifecycle**: counting `pgrep -f req_llm_mcp_proxy` across 50 sequential tool-using calls → process count never exceeds 1 mid-call and is 0 between calls (sidecar process gone, temp socket file gone, temp `--mcp-config` file gone).
- **CLI args wiring**: with user tools registered, argv contains `--mcp-config <path>` AND `--strict-mcp-config`. With `:allowed_tools => :none` and no user tools, argv contains neither.
- `:allowed_tools` interaction: when only `["Read"]` is allowed *and* a user-defined `weather` tool is registered, both appear (user-defined via MCP, built-in via `--allowedTools`); `:allowed_tools => :none` and no user tools → no `--mcp-config` flag.
- Tool callback returns `{:error, reason}` → MCP response carries `isError: true`; the CLI re-prompts the model with the tool failure; final response includes the model's recovery turn; `response.metadata[:tool_errors]` is non-empty.
- Tool callback raises an exception → same observable behavior; the exception class is in `response.metadata[:tool_errors]`; no crash propagates to the caller.
- Tool callback that returns a non-string (e.g., a map) → encoded as JSON via `Jason.encode!/1`; CLI receives a text block containing the JSON.
- Edge case — tool name collision with a built-in (`Read`): the user-defined tool wins under the MCP namespace and the built-in is suppressed by the CLI per its tool-resolution rules; assert via a `tool_use` event whose `id` namespace shows `mcp__req-llm-tools__Read` (the CLI's MCP-namespaced tool naming convention).
- Edge case — long tool result (>1MB): writes succeed via the Unix socket; CLI processes; final response is correct.
- Concurrent tool dispatch (two `tool_use` blocks in one turn): callbacks dispatched in arrival order; sidecar serializes responses on the socket.
- Permission denials: `:allowed_tools => :none` + model attempts `Bash` → `response.metadata[:permission_denials]` is non-empty; no crash.
- Cleanup: after a tool-using call completes (success or failure), the MCP sidecar OS process is gone, the temp socket file is unlinked, the temp `--mcp-config` file is deleted. Verify via shell out: no stragglers in `/tmp/req_llm_*.sock`, no `req_llm_mcp_proxy` processes.

**Verification.**
- `mix test test/provider/claude_agent/tools_test.exs` passes.
- `mix test --warnings-as-errors` is clean.

---

### U5. Built-in tools gating and session resumption

**Goal.** Make the user-facing option surface for built-in tools (`:allowed_tools`, `:disallowed_tools`) and session resumption (`:session_id`, `:previous_response_id`) behave correctly end-to-end. This is small but discrete — easier to verify in its own unit than mixed into U2/U3.

**Requirements.** R6, R7

**Dependencies.** U1 (option schema), U2 (CLI arg building), U3 (streaming arg building).

**Files.**
- `lib/req_llm/providers/claude_agent.ex` — translate options into adapter context fields.
- `lib/req_llm/providers/claude_agent/cli.ex` — extend `build_args/1`.
- `test/provider/claude_agent/option_validation_test.exs` (extend from U1).

**Approach.**
- `:allowed_tools => [list]` → `--allowedTools <comma-joined list>`. `["Bash(git *)", "Edit"]` is a valid input — the CLI parses pattern syntax itself; ReqLLM just joins.
- `:allowed_tools => :default` → no flag (CLI default).
- `:allowed_tools => :none` → `--allowedTools ""` (CLI special-cases empty string as "disable all tools").
- `:disallowed_tools => [list]` → `--disallowedTools <comma-joined>`.
- `:session_id => "<uuid>"` → `--resume <uuid>`. Per CLI docs, must be a valid UUID; validation happens at the option layer in U1.
- `:previous_response_id` is an alias for `:session_id` for naming-parity with OpenAI/Codex (`lib/req_llm/providers/openai_codex.ex:74-78`); supplying both is rejected in U1.
- Document that `--continue` (latest session) is *not* supported in v1 — too magic; callers must hold the UUID themselves.

**Test scenarios.**
- `:allowed_tools => ["Read", "Bash"]` → argv contains `--allowedTools "Read,Bash"`.
- `:allowed_tools => :default` → argv contains no `--allowedTools` flag.
- `:allowed_tools => :none` → argv contains `--allowedTools ""` (literally empty-string value).
- `:disallowed_tools => ["WebFetch"]` → argv contains `--disallowedTools WebFetch`.
- Combined: `:allowed_tools => ["Read"], :disallowed_tools => ["Bash"]` → both flags present.
- `:session_id => "550e8400-e29b-41d4-a716-446655440000"` → argv contains `--resume 550e8400-…`; the returned `Response` metadata includes the *server-assigned* session_id (which equals the one supplied if the resume succeeded).
- `:previous_response_id` alone behaves identically to `:session_id`.
- Both `:session_id` and `:previous_response_id` provided → request rejected with `Invalid.Parameter`.
- Live test (covered in U8): `:session_id` actually resumes — first call says "my name is Bob", second call with the captured session_id can recall "Bob".

**Verification.**
- `mix test test/provider/claude_agent/option_validation_test.exs` passes (now extended).
- `mix test --warnings-as-errors` is clean.

---

### U6. Usage and cost extraction from the terminal `result` event

**Goal.** Populate `Response.usage` (and `StreamResponse` metadata) with token counts pulled from the CLI's terminal `result` event, and feed them through the existing `Step.Usage` pipeline so cost figures appear in the same fields a caller would see for the HTTP `:anthropic` provider.

**Requirements.** R8

**Dependencies.** U2, U3.

**Files.**
- `lib/req_llm/providers/claude_agent/usage.ex` — `from_result/2` builds a usage map.
- `lib/req_llm/providers/claude_agent.ex` — implement `extract_usage/2`.
- `test/provider/claude_agent/usage_test.exs`

**Approach.**
- The CLI's `result.usage` shape (verified in protocol research):
  ```json
  {
    "input_tokens": 3,
    "cache_creation_input_tokens": 6609,
    "cache_read_input_tokens": 13955,
    "output_tokens": 17,
    "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0},
    "iterations": [...]
  }
  ```
  This is byte-compatible with the HTTP `/v1/messages` usage shape that `Anthropic.extract_usage/2` already handles (`lib/req_llm/providers/anthropic.ex:415-430`).
- `extract_usage/2` for `:claude_agent` is therefore a thin wrapper: delegate to `Anthropic.extract_usage/2` after normalizing the body to the same `%{"usage" => …}` envelope.
- The existing `ReqLLM.Step.Usage` (`lib/req_llm/step/usage.ex`) consumes the standardized map and runs the pricing pipeline against the Anthropic registry entry (because the model's `provider_model_id` resolves through the Anthropic catalog).
- The CLI's `total_cost_usd` is also captured but kept separate: it reflects what the CLI thinks the cost *would* be at API rates *including its built-in system-prompt overhead*, which is not what subscription users pay. ReqLLM should populate the standard usage / cost fields from the per-turn token counts and expose `total_cost_usd` only under `response.metadata[:cli_reported_cost_usd]` so callers can compare if they want.
- `modelUsage` (sub-model breakdown — e.g., Haiku used for routing) is exposed under `response.metadata[:model_usage_breakdown]` but does not affect the headline `cost`/`tokens` fields.

**Test scenarios.**
- Happy path: terminal result with `input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 200, cache_read_input_tokens: 400` → `response.usage.input_tokens == 100`, `response.usage.output_tokens == 50`, `response.usage.cache_creation_tokens == 200`, `response.usage.cache_read_tokens == 400`.
- Cost: same fixture against `claude-sonnet-4-5-20250929` → `response.usage.cost.input_cost` equals what the Anthropic pricing entry would compute for those token counts (compare directly to `ReqLLM.generate_text("anthropic:claude-sonnet-4-5-20250929", …)` with the same usage map).
- CLI-reported cost: `response.metadata[:cli_reported_cost_usd]` equals the `total_cost_usd` in the fixture (e.g., `0.029…`).
- Edge case — `result.usage` missing fields (older CLI?): defaults to `0` for missing token types; no crash.
- Edge case — model not in Anthropic registry: usage is populated, cost is `nil` or zero with a `metadata.cost_warning`.
- Streaming: same usage assertions apply against `StreamResponse.usage` after `await_metadata/2`.
- `modelUsage` exposure: response.metadata[:model_usage_breakdown] mirrors the fixture's `modelUsage` map.

**Verification.**
- `mix test test/provider/claude_agent/usage_test.exs` passes.
- Manual: `iex` against a real call, assert cost > 0 and roughly matches `(input_tokens / 1M) * input_price + (output_tokens / 1M) * output_price`.

---

### U7. `generate_object/4` via tool-output-as-JSON

**Goal.** Implement `generate_object/4` so callers can request structured JSON output validated against a Zoi/JSON Schema. Following the requirements, the implementation rides on top of `generate_text` + a synthetic `structured_output` tool whose schema is the caller's schema.

**Requirements.** R14

**Dependencies.** U2, U4, U5, U6.

**Files.**
- `lib/req_llm/providers/claude_agent.ex` — implement `prepare_request(:object, …)` mirroring `Anthropic.prepare_strict_tool_request/4` (`lib/req_llm/providers/anthropic.ex:310-337`).
- `test/provider/claude_agent/object_test.exs`
- `test/support/claude_agent_fixtures/structured_output.jsonl`

**Approach.**
- Reuse the `prepare_strict_tool_request/4` pattern from the HTTP provider: build a `ReqLLM.Tool` named `structured_output` whose `parameter_schema` is the caller's compiled schema; set `tool_choice` to force its use; route through the normal `:chat` path; let U4's tool dispatch capture the tool input as the structured object.
- The `Generation.execute_generate_object/7` flow (`lib/req_llm/generation.ex:337-370`) handles post-processing identically across providers, including type coercion via `coerce_object_types/2` — we just need to surface the tool's input args as `response.object`.
- The Anthropic provider's logic for choosing between `:json_schema` and `:tool_strict` modes (`lib/req_llm/providers/anthropic.ex:222-285`) is *not* needed here — there's no native JSON-schema path in v1. The `:object` operation always routes through the tool-strict path.
- **Tool name namespace caveat (verified during deepening).** Because user-defined tools are advertised via the MCP sidecar, the CLI exposes them as `mcp__req-llm-tools__<name>` to the model — not as bare `<name>`. The U4 `tool_use` content blocks carry the prefixed name. U7's object extractor matches by *suffix* (the last path segment after `__`), not the full name, so it survives this prefix without leaking the namespace to callers. Verify in test that `response.object` is unprefixed.
- **Thinking blocks before tool calls (verified during deepening).** Models can emit a `thinking` content block before the `structured_output` tool call. The extractor must scan the assistant message's content blocks for the *first* `tool_use` whose name has the `structured_output` suffix, not assume the tool call is the first or only block. If the assistant emits text + thinking but no `tool_use`, that's the existing "no structured output produced" error path.
- The `tool_choice` mechanism (force `structured_output`) does not currently work for the CLI path the same way it does over HTTP — CLI tools are advertised via MCP, and the CLI does not honor a `tool_choice` directive applied to MCP-namespaced tools. The implementer should validate this during U7 and, if `tool_choice` is ignored, fall back to a system-prompt prefix instructing the model to call `structured_output` immediately. Flag as Q4 below if it requires a workaround.

**Test scenarios.**
- Happy path: schema `[name: :string, age: :integer]`, fake CLI returns a tool_use with `%{"name" => "Alice", "age" => 30}` → `ReqLLM.generate_object("claude_agent:…", "Give me a person", schema)` returns `{:ok, %Response{object: %{name: "Alice", age: 30}}}`.
- **MCP namespace handling**: fake CLI emits a `tool_use` block whose `name` is `mcp__req-llm-tools__structured_output` (CLI's MCP-prefixed shape, verified during deepening) → extractor strips the prefix and surfaces the unprefixed object; `response.object` does not contain the prefix.
- **Thinking blocks before tool call**: fake CLI emits content sequence `[thinking, text, tool_use(structured_output, {...})]` → extractor finds the tool call regardless of position; `response.object` is populated correctly; `response.metadata[:thinking]` carries the thinking content (consistent with how Anthropic HTTP provider surfaces it).
- Type coercion: CLI returns `%{"age" => "30"}` (string) → existing `coerce_object_types` converts to integer.
- Required-field missing: CLI returns `%{"name" => "Alice"}` (no age) → validation error surfaces with the missing-field message.
- Schema with nested objects: CLI returns nested JSON → preserved through the pipeline.
- Schema with arrays: CLI returns array values → preserved.
- Error path — CLI emits text + thinking but never a `tool_use`: returns `%ReqLLM.Error.API.Response{reason: ~r/no structured output produced/}`. (`tool_choice` may or may not be honored on the MCP path — Q4.)
- Edge case — assistant message ends with no tool_use and no text: error path same as above.
- Streaming `generate_object/4` is not part of this unit — it's not currently in the v1 scope (only `generate_text`, `stream_text`, tools, `generate_object`).

**Verification.**
- `mix test test/provider/claude_agent/object_test.exs` passes.
- `mix test --warnings-as-errors` is clean.

---

### U8. Test harness: fake CLI binary, fixture format, live-test gating

**Goal.** Solidify the fake-binary scaffold used by U2–U7 into a self-contained test harness, then add the live-test layer behind a tag + env flag. After this unit, contributors can run the full provider test suite without ever installing Claude Code.

**Requirements.** R16

**Dependencies.** U2 (and all units that fed it scenarios).

**Files.**
- `test/support/claude_agent_cli.exs` — finalized fake binary; handles all fixture types; supports `--version`, scripted exit codes, scripted stderr, tool round-trip pacing.
- `test/support/claude_agent_fixtures/*.jsonl` — finalized fixture set covering every test scenario in U2–U7.
- `test/coverage/claude_agent/live_test.exs` — `@moduletag :live`; gated on `REQ_CLAUDE_AGENT_LIVE=1`; reuses the `ReqLLM.ProviderTest.Comprehensive` macro where it fits.
- `test/support/helpers.ex` (extend) — `with_claude_agent_fake/2` helper that configures the `:claude_binary` path and any required fixture metadata for a test.
- `mix.exs` — add the fake-binary build target if needed (`elixirc_paths/1` already includes `test/support` for `:test`; verify no additional config is needed).
- `test/test_helper.exs` — exclude the `:live` tag by default (matches the existing `:coverage` and `:integration` exclusion pattern at `test/test_helper.exs:14`).
- `AGENTS.md` — append a "Claude Agent CLI testing" subsection under "Testing & Fixture Workflow" explaining how to run live tests and update fixtures.

**Approach.**
- The fake binary is an Elixir escript (not a shell script). Reasons: (a) cross-platform (Windows-on-CI works), (b) JSON encoding is trivial, (c) we can reuse Jason. It's invoked via `:claude_binary` provider option pointing at the compiled escript path.
- Each fixture file is a JSONL document of two parts:
  1. Header line: `{"argv_expectations": [...], "stderr": "...", "exit_code": 0, "version": "2.1.119"}`
  2. Stream events (one per line) in the order they should be emitted, with optional `{"_pause_until": "tool_result"}` markers to gate emission on input events.
- Tool round-trip pacing: when the fake binary sees a `_pause_until: "tool_result"` marker, it stops emitting and waits for a `user`/`tool_result` event on stdin matching the expected `tool_use_id`, then resumes the script.
- Live test gating: `@moduletag :live` + a `setup_all` that calls `:ok = ensure_claude_cli_live!()` which checks (a) `System.get_env("REQ_CLAUDE_AGENT_LIVE") == "1"`, (b) `System.find_executable("claude") != nil`, (c) `claude auth status` returns ok (small `System.cmd` call). If any check fails, `ExUnit.skip/0` with a clear reason.
- Live tests run against `claude_agent:claude-3-5-haiku-20241022` (cheapest model the catalog has) for cost reasons; the haiku is enough to validate every code path because the wire protocol is model-agnostic.

**Test scenarios.**
- Fake binary `--version`: returns the version from the fixture header.
- Fake binary argv: argv matches `argv_expectations` from the fixture (or echoes argv to a temp file the test reads).
- Fake binary exit code: matches fixture `exit_code`; non-zero exits surface the right error class.
- Fake binary stderr: matches fixture; visible in error context.
- Fake binary tool round-trip: pauses on `_pause_until`, resumes on matching `tool_result`, errors if mismatched.
- Fake binary unhandled fixture: tests with no fixture configured fail loudly (not silently hang).
- Live test suite: `REQ_CLAUDE_AGENT_LIVE=1 mix test test/coverage/claude_agent/live_test.exs` runs against a real `claude` install and passes.
- Live test suite (skip): without the env flag, the file's tests are skipped (not failed); without the binary, same.
- Live test suite includes: `generate_text` (basic), `stream_text` (basic), `generate_text` with `:allowed_tools => :none` (to confirm no built-in tools are invoked), `generate_text` with one user-defined tool (the canonical `add(a, b)` example), `generate_object` against a small schema.

**Verification.**
- `mix test test/provider/claude_agent/` passes without `claude` installed (or by overriding `PATH`).
- `unset REQ_CLAUDE_AGENT_LIVE && mix test test/coverage/claude_agent/` skips all live tests.
- `REQ_CLAUDE_AGENT_LIVE=1 mix test test/coverage/claude_agent/` passes on a host with a valid `claude` install.
- `mix quality` passes (format + warnings-as-errors + dialyzer + credo).

---

### U9. Delivery: docs, CHANGELOG, fork remote, branch push

**Goal.** Land the work in shippable form: a user-facing guide, CHANGELOG entry, README mention, and the actual git delivery — to the *user's fork*, never to upstream `agentjido/req_llm`.

**Requirements.** R17

**Dependencies.** All previous units complete.

**Files.**
- `guides/claude-agent-provider.md` — user-facing guide: install `claude`, run `claude auth login` once, supported models, supported / unsupported options, version pinning, tool-loop semantics, cost interpretation note (subscription vs API rates), known limitations (no embeddings, no images, no streaming `generate_object` in v1).
- `mix.exs` — add the new guide to the `docs.extras` list (mirror the existing entries at `mix.exs:35-44`).
- `README.md` — add a line under the providers section noting `:claude_agent` exists and linking to the guide.
- `CHANGELOG.md` — add an entry under unreleased.
- Branch name suggestion: `feat/claude-agent-provider`. Push target: a `fork` remote pointing at the user's fork (must be added — current `origin` points at upstream, see "Pre-delivery" below).

**Approach.**
- Write the guide first; it serves as a final cross-check of the public option surface.
- The guide must explain:
  - The CLI is the auth boundary; ReqLLM does not log in for you.
  - Cost figures reflect Anthropic API pricing for the underlying model and do **not** equal the subscription cost (the subscription is flat-rate). They're useful for *comparison* with API-direct usage; they are not bills.
  - `:session_id` semantics — the UUID must come from a prior CLI session; bring-your-own (custom UUIDs you generate) won't resume anything (no server-side state). Document this clearly.
  - The CLI's own system prompt + tools list inflate `cache_creation_input_tokens` in the result event; this is normal and not a bug.
- Pre-delivery git hygiene checklist:
  - Verify current remote setup (`git remote -v`); the worktree starts on `agentjido/req_llm` as `origin`.
  - **Do not push to `origin`.** Add the user's fork as `fork` (e.g., `git remote add fork git@github.com:<user>/req_llm.git`). The exact fork URL is the user's responsibility — the plan documents the *pattern*, the implementer or user provides the URL.
  - Push: `git push -u fork feat/claude-agent-provider`.
  - PR (optional): if the user wants a PR, it must target the fork's `main` branch, not upstream. The plan documents this; the implementer does not auto-open a PR.

**Test expectation: none — pure documentation and delivery scaffolding.** The non-test items in this unit are validated by:
- `mix docs` builds cleanly with the new guide listed.
- `mix quality` is clean.
- Manual review of the guide for accuracy against the implementation.

**Verification.**
- `mix docs` produces an HTML page for `guides/claude-agent-provider.md`.
- `grep -c claude_agent README.md` > 0.
- `grep -c claude_agent CHANGELOG.md` > 0.
- `git remote -v` shows a `fork` remote, not just `origin`.
- `git log fork/feat/claude-agent-provider --oneline` shows the new commits on the fork.
- No commits are pushed to `origin` (upstream).

---

## System-Wide Impact

- **`lib/req_llm/stream_server.ex`** — one new dispatch branch added at `lib/req_llm/stream_server.ex:424-430`. This is the only file outside the new provider directory that materially changes. The new branch is additive (selects a third transport client); existing `:websocket` and default arms keep their behavior. Affects every streaming code path indirectly via that one dispatch — guarded by U3 regression tests against `:anthropic` and `:openai` streaming.
- **`lib/req_llm/providers/anthropic/response.ex`** — read-only dependency from the new provider. The new provider calls `decode_stream_event/3` and the response-shape builders. No edits. If the Anthropic provider ever changes those modules' contracts, both providers must update; U3 / U6 regression tests will catch breakage immediately.
- **`mix.exs`** — `docs.extras` gets one new entry. No new runtime dependencies (the MCP stdio sidecar is a hand-rolled GenServer in v1).
- **`config/config.exs`** — no edits required. The new provider has no env flag default.
- **`priv/models_dev/`** — no edits. The provider reuses the Anthropic catalog rather than ships its own.
- **`test/test_helper.exs`** — add `:live` to the default-exclude list if it's not already there (it isn't — only `:coverage` and `:integration` are excluded at `test/test_helper.exs:14`).
- **`AGENTS.md`** — one new subsection under "Testing & Fixture Workflow". No edits to "Provider Architecture" — the new provider conforms.
- **CI** — no changes required for unit tests. If the project wants to run live tests in CI, a separate scheduled job with `REQ_CLAUDE_AGENT_LIVE=1` and a logged-in `claude` install is needed; this is out of scope for v1 but called out in U9.

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **CLI stream-json schema changes between releases** | High over months, low over weeks | Provider breaks for users on a newer CLI | D4: pin minimum version with `claude --version` check; document the pin and the bump procedure; fixtures are versioned alongside the binary version |
| **MCP sidecar approach is wrong for tool advertisement** | Low (verified against CLI 2.1.119 during deepening) | U4 architecture rework | Validated via direct probe — see D3. The `mcp_servers[].status` field in the init event gives the implementer a clean fail-fast point if registration ever stops working. Watch: future CLI versions may add a stream-json tool-definitions message, at which point retire the sidecar |
| **CLI does not honor `tool_choice` on MCP-advertised tools** | Medium | `generate_object/4` may not consistently force the structured_output tool, producing intermittent "no structured output" errors | Q4 records the workaround (system-prompt prefix via `--append-system-prompt`) — small to ship if needed. U7 includes a live-test scenario specifically to confirm; tests catch this in the first run |
| **Zombie `claude` processes leak under cancellation / crash** | Medium | OS resource exhaustion in long-running BEAM nodes | Explicit `Port.close/1` in adapter `after` blocks (U2); link the streaming task to the StreamServer (U3); test scenario "100 sequential calls leave zero zombies"; integration smoke test that runs `pgrep claude` between test files |
| **Per-call CLI spawn cost (1-3s) makes the provider slow for chat-loop apps** | High for chat-loop use cases | Latency complaints | Documented in the guide. v1 ships per-call spawn; session pool is a follow-up. Callers can use `:session_id` to keep model state warm even if the BEAM has to re-spawn |
| **Fake binary protocol drifts from real CLI protocol** | Medium | Tests pass while real-world flow is broken | U8 live suite runs the same scenarios against the real binary; CI scheduled run on a host with a `claude` login; fixture format includes the CLI version so drift is detectable |
| **Reusing `Anthropic.Response` private functions couples the providers** | Low — they're public functions in the module | Surprise breakage when the HTTP provider is refactored | The decoder functions are documented (`@impl ReqLLM.Provider`); coupling is explicit; both providers' streaming tests share enough overlap that a contract break shows up immediately |
| **Cost figures confuse users (CLI says $0.08, user paid $0 from their flat subscription)** | High | Support burden, perception of bugs | U6 surfaces *two* cost figures (computed-from-tokens vs CLI-reported); guide explains the difference; relevant fixture asserts both are exposed |
| **Built-in tool gating doesn't match the CLI's actual semantics** | Medium | Users surprised when `Bash` is allowed even though they didn't list it | U5 test scenarios cover the `:default`, `:none`, and explicit-list cases; live test confirms argv shape matches user expectation |
| **Concurrent streams cross-contaminate via shared state** | Low | Wrong content delivered to wrong consumer | Each call spawns its own Port and StreamServer (per existing pattern); U3 has an explicit concurrency test |

---

## Open Planning Questions

Resolved questions are kept here for traceability; live questions sit at the bottom. None block the rest of the plan.

**Resolved during deepening (CLI 2.1.119 probes).**

- **Q1 (U4) — RESOLVED.** The CLI does *not* expose a stream-json-level tool-advertisement mechanism in 2.1.119. The MCP stdio sidecar path is the only viable one. Verified config shape and init-event `mcp_servers[].status` reporting; both are now part of D3 and U4 with concrete shape and failure-detection logic. Drift watch: if a future CLI version adds a stream-json `tool_definitions` directive, the implementer should prefer it and retire the sidecar.
- **Q2 (U2) — RESOLVED.** Use `Port.open/2` with `[:binary, :exit_status, :hide, :stderr_to_stdout, args: …]` and demultiplex per line: any line that doesn't parse as a known stream-json `type` is treated as diagnostic. Rejected alternatives (wrapper script, `:exec` dep, `System.cmd/3` with `:input`) recorded in U2's Approach for traceability.

**Live (to be answered during the named unit).**

- **Q3 (U6):** Should `response.metadata[:cli_reported_cost_usd]` be the headline cost field (CLI's honest opinion) or the "computed from token counts × Anthropic API rates" figure (comparable to the HTTP provider)? Plan defaults to the latter for cross-provider parity, with the CLI's figure exposed under metadata. Confirm during U6 with a quick check of how downstream observability dashboards in the project (if any) consume `response.usage.cost`.
- **Q4 (U7):** Does the CLI honor `tool_choice = {type: "tool", name: "structured_output"}` when the tool is advertised through MCP (`mcp__req-llm-tools__structured_output`)? Anthropic's HTTP API honors `tool_choice` for native tools, but the CLI's MCP path may treat MCP tools as ordinary suggestions. If `tool_choice` is silently ignored, the workaround is to prepend a short system-prompt instruction ("Respond by immediately calling the `structured_output` tool.") via `--append-system-prompt`. Validate during U7 with a single live test; the workaround is small enough to ship if needed without restructuring U7.
- **Q5 (U3 / future):** The `system/init` event carries an extensive `tools`, `agents`, `skills`, and `plugins` list that reflects the host's full Claude Code environment, including third-party plugins the user has installed. This is leakage of host-side configuration into ReqLLM's session. Plan ships v1 ignoring these fields; a follow-up could surface them as a `response.metadata[:cli_environment]` summary for observability. Not blocking.

---

## Documentation Plan

- `guides/claude-agent-provider.md` — primary user-facing doc (introduced in U9).
- `README.md` — one-line mention with link to the guide.
- `CHANGELOG.md` — under unreleased, "Added: `:claude_agent` provider backed by the Claude Code CLI."
- `AGENTS.md` — testing-section subsection on running live tests and updating fake-binary fixtures.
- Module docs (`@moduledoc`) for `ClaudeAgent`, `ClaudeAgent.CLI`, `ClaudeAgent.Protocol`, `ClaudeAgent.ReqAdapter`, `ClaudeAgent.StreamClient`, `ClaudeAgent.Tools`, `ClaudeAgent.Usage` — each describes its responsibility and the supported invariants, not implementation details (per the project's `AGENTS.md:107-113` "no inline comments" rule and the established Anthropic-provider module-doc style).

---

## Operational / Rollout Notes

- The provider has no runtime config flags. It is registered automatically at boot via `ReqLLM.Providers.initialize/0` because it `use`s the `ReqLLM.Provider` behavior (`lib/req_llm/providers.ex:99-110`).
- No migration is required for existing callers — the provider is new and additive.
- Users who want to opt in: install `claude`, run `claude auth login`, change their model spec from `"anthropic:…"` to `"claude_agent:…"`. Nothing else.
- If the user runs unit-test-only CI, the new provider's tests run in the existing `mix test` invocation. If the user runs live-coverage CI, they add `REQ_CLAUDE_AGENT_LIVE=1` and a `claude auth` step.
- Rollback story: the provider is one directory and one ten-line dispatch branch in `StreamServer`. Reverting is trivially clean.

---

## Pre-Delivery Checklist

Before U9 push:

- [ ] `mix quality` passes (format + warnings-as-errors + dialyzer + credo).
- [ ] `mix test` passes locally without `claude` installed (or with it).
- [ ] `REQ_CLAUDE_AGENT_LIVE=1 mix test test/coverage/claude_agent/` passes on a host with a real `claude auth` login.
- [ ] `mix docs` builds without warnings; new guide is in the output.
- [ ] No edits to `lib/req_llm/providers/anthropic.ex` except dependency-style imports (verify with `git diff main -- lib/req_llm/providers/anthropic.ex`).
- [ ] No commits pushed to `origin` (upstream `agentjido/req_llm`); all work lives on the `fork` remote.
- [ ] CHANGELOG entry is dated and signed.
- [ ] The branch is rebased onto the latest fork `main` to keep history linear.
