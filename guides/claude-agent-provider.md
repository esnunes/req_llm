# `:claude_agent` provider — Claude through the local CLI

The `:claude_agent` provider routes Anthropic Claude requests through the
locally installed Claude Code CLI (`claude` binary) instead of the HTTP
`/v1/messages` endpoint. It lets callers spend their Claude Pro / Max / Team
subscription in place of paying API credits per token, while keeping every
public ReqLLM entry point (`generate_text/3`, `stream_text/3`, tool calling,
`generate_object/4`) behaviorally indistinguishable from any other
provider.

## Prerequisites

1. Install the [Claude Code CLI](https://claude.com/code).
2. Authenticate once with `claude auth login`.
3. Confirm the version: `claude --version` should report **≥ 2.1.119**.

ReqLLM does **not** manage authentication or wrap `claude login`. The CLI
is the auth boundary; if `claude` is broken, this provider is broken.

## Quick start

```elixir
{:ok, response} =
  ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", "Hello!")

ReqLLM.Response.text(response)
#=> "Hi there! How can I help you today?"
```

Streaming works the same way:

```elixir
{:ok, stream_response} =
  ReqLLM.stream_text("claude_agent:claude-sonnet-4-5-20250929", "Tell me a joke")

stream_response.stream
|> Stream.filter(&(&1.type == :content))
|> Enum.each(&IO.write(&1.text))
```

## Supported models

Any Anthropic Claude model from the standard ReqLLM model catalog can be
addressed with the `claude_agent:` prefix. Models like
`claude_agent:claude-sonnet-4-5-20250929` reuse the entry from the
`:anthropic` provider for cost and capability metadata — only the request
path changes.

```elixir
ReqLLM.model!("claude_agent:claude-3-5-haiku-20241022")
ReqLLM.model!("claude_agent:claude-sonnet-4-5-20250929")
```

## Provider options

All options below live under `:provider_options`.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `:allowed_tools` | list / `:default` / `:none` | `:default` | Built-in Claude Code tools allowed (`["Read", "Bash"]`, `:none` disables all, `:default` lets the CLI decide). |
| `:disallowed_tools` | list of strings | — | Forbid specific built-in tools (forwarded as `--disallowedTools`). |
| `:session_id` | UUID string | — | Resume an existing CLI session via `--resume`. Must come from a prior CLI session. |
| `:previous_response_id` | UUID string | — | OpenAI Codex-style alias for `:session_id`. Supplying both raises. |
| `:claude_binary` | path | `System.find_executable("claude")` | Override the binary path (useful for tests / non-PATH installs). |
| `:cli_timeout` | ms | `120_000` | Hard timeout before the CLI subprocess is killed. |
| `:include_partial_messages` | boolean | `true` (streaming), `false` (non-streaming) | Pass `--include-partial-messages` for per-token deltas. |
| `:permission_mode` | atom | `:default` | Forwarded as `--permission-mode` when not `:default`. |
| `:cli_env` | list of `{string, string}` | — | Extra environment vars injected into the subprocess. |
| `:minimum_cli_version` | semver string | `"2.1.119"` | Override the pinned minimum CLI version (mostly for tests). |

## Cost interpretation

The CLI reports a `total_cost_usd` figure for each turn. That value is what
the call **would** cost at standard Anthropic API rates — including the
CLI's own system prompt overhead. It does **not** match what you actually
pay against a flat-rate subscription.

ReqLLM populates the standard `Response.usage[:cost]` from the per-turn
token counts using the existing Anthropic pricing entry (so it's directly
comparable to the HTTP `:anthropic` provider), and exposes the CLI's
self-reported figure separately:

```elixir
response.usage[:cost]                          # comparable to :anthropic
response.provider_meta[:cli_reported_cost_usd] # CLI's view
```

## Tool use

V1 supports both **built-in CLI tools** (Read, Bash, Write, WebFetch, …)
via `:allowed_tools` / `:disallowed_tools`, and **user-defined
`ReqLLM.Tool` specs** via the CLI's bidirectional control protocol.

User-defined tools are advertised as an *in-process SDK MCP server*: at
session start the provider sends an `initialize` control_request with the
server name `req-llm-tools` so the CLI knows the server lives in our BEAM
node. When the model emits a `tool_use` block targeting
`mcp__req-llm-tools__<tool-name>`, the CLI sends a JSON-RPC `tools/call`
back to us over stdin; we dispatch to the matching `ReqLLM.Tool`
callback in-process and reply with a `control_response` carrying the
result. No subprocess, no socket, no MCP sidecar — just the same stdin
already in play for stream-json events.

```elixir
{:ok, weather} =
  ReqLLM.Tool.new(
    name: "weather",
    description: "Get the weather in a city.",
    parameter_schema: [city: [type: :string, required: true]],
    callback: fn args -> {:ok, "sunny in #{args[:city]}"} end
  )

{:ok, response} =
  ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929",
    "What's the weather in Paris?",
    tools: [weather])
```

`generate_object/4` rides the same channel: the provider forces a
`structured_output` tool whose `parameter_schema` is the caller's Zoi
schema, lets the CLI invoke it, and exposes the captured args as
`response.object`.

Caller-side tool errors (`{:error, reason}` from the callback) surface
as MCP `isError: true` to the model and accumulate under
`response.private[:tool_errors]` so the caller can inspect what went
wrong without crashing the request.

## Provider metadata

Both the streaming and non-streaming paths populate
`response.provider_meta` with CLI session and turn metadata:

| Key | Source | Notes |
|---|---|---|
| `:cli_session_id` | `system/init` + `result` | Pass back as `:session_id` to resume. |
| `:cli_api_key_source` | `system/init` | `"none"` for subscription auth. |
| `:cli_mcp_servers` | `system/init` | Status of each MCP server we registered (e.g. `req-llm-tools`). |
| `:cli_rate_limit` | `rate_limit_event` | Last value wins. |
| `:cli_reported_cost_usd` | `result.total_cost_usd` | CLI's own cost estimate. Not your bill on a subscription. |
| `:cli_terminal_reason` | `result.terminal_reason` | `"completed"`, `"max_tokens"`, `"cancelled"`, `"incomplete"`. |
| `:cli_permission_denials` | `result.permission_denials` | Non-empty when the model tried a tool that `--allowedTools`/`--disallowedTools` blocked. |
| `:cli_model_usage_breakdown` | `result.modelUsage` | Per-sub-model token counts (e.g. routing Haiku). |

For streaming, these arrive via the standard
`ReqLLM.StreamResponse.to_response/1` /
`ReqLLM.StreamResponse.MetadataHandle.await/1` channel — the CLI's
`system/init` and terminal `result` events are forwarded into the
StreamServer's metadata accumulator just like the per-turn `stream_event`
deltas, so the assembled `Response` has the same `provider_meta` shape
regardless of which path was used.

## Known limitations

- No embeddings, no image generation, no transcription, no rerank — the
  CLI does not expose any of these surfaces.
- Each call spawns its own subprocess (1–3 s startup cost). Session reuse
  is opt-in via `:session_id`; a pooled implementation is a follow-up.
- No HTTP fallback. If `claude` is missing, requests fail with a typed
  `ReqLLM.Error.Invalid.Capability` (wrapped by the standard
  `ReqLLM.Error.API.Request` envelope from `Step.Error`).
- Cost figures are informational only when running on a subscription.

## Testing

The provider ships with a Bash-based fake CLI at
`test/support/claude_agent/fake_cli.sh` plus JSONL fixtures. Tests drive
the provider end-to-end by setting `:claude_binary` to the fake path and
the `REQ_LLM_FAKE_CLAUDE_FIXTURE` env var to the desired fixture; the
`ReqLLM.Test.ClaudeAgent` helper module handles the bookkeeping. No real
`claude` install is required to run `mix test`.

A live test layer (real `claude` binary, gated on
`REQ_CLAUDE_AGENT_LIVE=1` plus the `:live` ExUnit tag) is planned as a
follow-up.
