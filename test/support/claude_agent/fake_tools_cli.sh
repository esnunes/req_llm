#!/usr/bin/env bash
# Interactive fake `claude` binary that exercises the control-protocol
# round-trip for tools tests.
#
# Behaviour:
#   - `--version` prints the version from REQ_LLM_FAKE_CLAUDE_VERSION
#     (default 2.1.119) and exits 0.
#   - Otherwise:
#       1. Read stdin lines until we see the user's prompt (the first
#          message whose "type" is "user" and is not a "tool_result").
#       2. Emit init + tool_use assistant block invoking `weather`.
#       3. Wait for a `control_request` `mcp_message` `tools/call` on
#          stdin and capture the JSON-RPC id from the inbound payload.
#       4. Reply with a `control_response` echoing the JSON-RPC id and a
#          synthetic tool result.
#       5. Emit a follow-up assistant message that references the tool
#          output, then a terminal `result` event.
#
# This is bash, so we keep the protocol noise to a minimum and rely on
# fixed-shape JSON lines.

set -u

for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    echo "${REQ_LLM_FAKE_CLAUDE_VERSION:-2.1.119}"
    exit 0
  fi
done

# Discard the initialize control_request (and ignore any other lines)
# until we see the user's first message.
while IFS= read -r line; do
  case "$line" in
    *'"type":"user"'*)
      break
      ;;
    *)
      :
      ;;
  esac
done

# Init event.
cat <<'JSON'
{"type":"system","subtype":"init","session_id":"sess-tools-1","model":"claude-sonnet-4-5-20250929","tools":[],"mcp_servers":[{"name":"req-llm-tools","status":"connected"}],"apiKeySource":"none"}
JSON

# Assistant message with a tool_use block.
cat <<'JSON'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"mcp__req-llm-tools__weather","input":{"city":"Paris"}}]}}
JSON

# CLI control_request → us. Note the static request_id for the test.
cat <<'JSON'
{"type":"control_request","request_id":"cli-1","request":{"subtype":"mcp_message","server_name":"req-llm-tools","message":{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"weather","arguments":{"city":"Paris"}}}}}
JSON

# Wait for the tool result on stdin. We accept either a control_response
# (the SDK pattern) or a stream-json `user`/`tool_result`. Both end the
# wait.
while IFS= read -r line; do
  case "$line" in
    *'"type":"control_response"'*)
      break
      ;;
    *'"tool_result"'*)
      break
      ;;
    *)
      :
      ;;
  esac
done

# Final assistant turn + terminal result.
cat <<'JSON'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"It is sunny in Paris."}]}}
{"type":"result","subtype":"success","is_error":false,"session_id":"sess-tools-1","terminal_reason":"completed","total_cost_usd":0.0003,"usage":{"input_tokens":12,"output_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"permission_denials":[]}
JSON

exit 0
