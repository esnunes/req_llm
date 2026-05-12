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

V1 supports the CLI's built-in tools (Read, Bash, Write, WebFetch, …) via
`:allowed_tools` / `:disallowed_tools`. **User-defined `ReqLLM.Tool` specs
are not yet wired up** — advertising them to the CLI requires an in-process
MCP stdio sidecar, which is a follow-up. Until then, passing `:tools` with
user-defined entries raises `ReqLLM.Error.Invalid.NotImplemented`.

`generate_object/4` follows the same constraint: the provider implements
the path on top of a forced `structured_output` tool, but until the MCP
sidecar lands you'll see the same `Invalid.NotImplemented` error.

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
