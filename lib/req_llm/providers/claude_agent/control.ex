defmodule ReqLLM.Providers.ClaudeAgent.Control do
  @moduledoc """
  Encoder/decoder for the Claude Code CLI's bidirectional control protocol.

  The control protocol runs over the same stdin/stdout pipes as stream-json
  events. Messages are JSON-line framed and use a discriminated `"type"`
  field; the discriminators relevant here are:

    * `"control_request"` — request sent by either side. We send one
      `"initialize"` request at startup so the CLI knows about our in-process
      SDK MCP server. The CLI sends `"mcp_message"` (JSON-RPC) requests when
      the model wants to list or call a user-defined tool.
    * `"control_response"` — reply, addressed to the matching `request_id`.

  See the Claude Code Elixir SDK's `lib/claude_code/cli/control.ex` for the
  protocol shape this module mirrors.
  """

  @doc """
  Build the initial `initialize` control request. We pass a single
  in-process SDK MCP server name; the CLI then routes `tools/list` and
  `tools/call` JSON-RPC messages back to us under that server name.
  """
  @spec initialize_request(String.t(), [String.t()]) :: {String.t(), map()}
  def initialize_request(request_id, sdk_mcp_servers) when is_list(sdk_mcp_servers) do
    {request_id,
     %{
       "type" => "control_request",
       "request_id" => request_id,
       "request" => %{
         "subtype" => "initialize",
         "sdkMcpServers" => sdk_mcp_servers
       }
     }}
  end

  @doc """
  Wrap a JSON-RPC response from our SDK MCP server in a `control_response`
  envelope addressed to the originating `request_id`.
  """
  @spec mcp_success_response(String.t(), map()) :: map()
  def mcp_success_response(request_id, jsonrpc_response) do
    %{
      "type" => "control_response",
      "response" => %{
        "subtype" => "success",
        "request_id" => request_id,
        "response" => jsonrpc_response
      }
    }
  end

  @doc """
  Wrap a JSON-RPC error response in a `control_response` envelope.
  """
  @spec mcp_error_response(String.t(), String.t()) :: map()
  def mcp_error_response(request_id, error_message) do
    %{
      "type" => "control_response",
      "response" => %{
        "subtype" => "error",
        "request_id" => request_id,
        "error" => error_message
      }
    }
  end

  @doc """
  Classify a decoded stream-json event into one of the control-protocol
  shapes, or `:not_control` for everything else.

  Returns:

    * `{:request, subtype, request_id, payload}` — peer sent us a request we
      may need to answer. `subtype` is `"mcp_message"`, `"can_use_tool"`,
      `"initialize"`, etc.
    * `{:response, subtype, request_id, payload}` — peer is replying to a
      request we issued earlier (e.g. our `initialize`).
    * `:not_control` — not a control message.
  """
  @spec classify(map()) ::
          {:request, String.t(), String.t(), map()}
          | {:response, String.t(), String.t() | nil, map()}
          | :not_control
  def classify(%{"type" => "control_request", "request_id" => id, "request" => req})
      when is_map(req) do
    {:request, Map.get(req, "subtype", "unknown"), id, req}
  end

  def classify(%{"type" => "control_response", "response" => resp}) when is_map(resp) do
    {:response, Map.get(resp, "subtype", "unknown"), Map.get(resp, "request_id"), resp}
  end

  def classify(_), do: :not_control

  @doc """
  Generate a unique request id for outbound control messages.
  """
  @spec new_request_id() :: String.t()
  def new_request_id do
    "req_llm_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
