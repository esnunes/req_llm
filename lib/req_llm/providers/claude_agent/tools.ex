defmodule ReqLLM.Providers.ClaudeAgent.Tools do
  @moduledoc """
  User-defined tool registry and JSON-RPC dispatch for the
  `:claude_agent` provider.

  We do not run an MCP stdio subprocess. Instead the `ClaudeCode` CLI
  treats us as an *in-process SDK MCP server* — we register a server
  name in the `initialize` control request, and the CLI then routes
  `tools/list` and `tools/call` JSON-RPC messages back to us over the
  control protocol. Tool callbacks run in the BEAM, with full access to
  closures over the calling process' state.

  This module exposes a small state struct and two operations: building
  the JSON-RPC response for a `tools/list` request, and dispatching a
  `tools/call` invocation against the registered `ReqLLM.Tool` callbacks.
  """

  alias ReqLLM.Providers.ClaudeAgent.Control

  @server_name "req-llm-tools"

  defmodule State do
    @moduledoc false
    defstruct registry: %{}, errors: []

    @type t :: %__MODULE__{
            registry: %{optional(String.t()) => ReqLLM.Tool.t()},
            errors: [String.t()]
          }
  end

  @doc """
  Name of the SDK MCP server we expose to the CLI. The CLI namespaces
  tool calls as `mcp__<server_name>__<tool_name>` for the model side;
  the JSON-RPC `tools/call` `params.name` comes back without the prefix.
  """
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc """
  Build a tools state from a keyword list's `:tools` entry. Returns
  `{:ok, state}` with either an empty registry (no user tools) or one
  keyed by tool name. Returns `{:error, exception}` when a tool entry is
  malformed.
  """
  @spec prepare(keyword()) :: {:ok, State.t()} | {:error, Exception.t()}
  def prepare(opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        {:ok, %State{}}

      [] ->
        {:ok, %State{}}

      tools when is_list(tools) ->
        Enum.reduce_while(tools, {:ok, %State{}}, fn
          %ReqLLM.Tool{} = tool, {:ok, acc} ->
            case tool.name do
              name when is_binary(name) and name != "" ->
                {:cont, {:ok, %{acc | registry: Map.put(acc.registry, name, tool)}}}

              _ ->
                {:halt,
                 {:error,
                  ReqLLM.Error.Invalid.Parameter.exception(
                    parameter: "tool name must be a non-empty string"
                  )}}
            end

          other, _ ->
            {:halt,
             {:error,
              ReqLLM.Error.Invalid.Parameter.exception(
                parameter: "expected %ReqLLM.Tool{} entries in :tools, got: #{inspect(other)}"
              )}}
        end)

      other ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "expected :tools to be a list, got: #{inspect(other)}"
         )}
    end
  end

  @doc """
  Returns `true` when the state has any registered user tools (meaning we
  should run the SDK MCP server initialization handshake).
  """
  @spec advertise?(State.t()) :: boolean()
  def advertise?(%State{registry: registry}), do: map_size(registry) > 0

  @doc """
  Dispatch an inbound MCP-over-control-protocol request. The control
  request must already have been classified as
  `{:request, "mcp_message", request_id, payload}` by `Control.classify/1`.

  Returns a `{response_event, new_state}` pair: the caller writes
  `response_event` back to the port.
  """
  @spec dispatch_mcp(String.t(), map(), State.t()) :: {map(), State.t()}
  def dispatch_mcp(request_id, request_payload, %State{} = state) do
    server_name = Map.get(request_payload, "server_name")
    message = Map.get(request_payload, "message", %{})

    cond do
      server_name != @server_name ->
        {Control.mcp_error_response(
           request_id,
           "Unknown MCP server: #{inspect(server_name)}"
         ), state}

      true ->
        handle_jsonrpc(request_id, message, state)
    end
  end

  defp handle_jsonrpc(request_id, %{"method" => "tools/list"} = msg, %State{} = state) do
    jsonrpc_id = Map.get(msg, "id")

    tools_list =
      state.registry
      |> Map.values()
      |> Enum.map(&tool_descriptor/1)

    response = %{
      "jsonrpc" => "2.0",
      "id" => jsonrpc_id,
      "result" => %{"tools" => tools_list}
    }

    {Control.mcp_success_response(request_id, response), state}
  end

  defp handle_jsonrpc(request_id, %{"method" => "tools/call"} = msg, %State{} = state) do
    jsonrpc_id = Map.get(msg, "id")
    params = Map.get(msg, "params", %{})
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case Map.fetch(state.registry, tool_name) do
      {:ok, tool} ->
        invoke_tool(tool, jsonrpc_id, arguments, request_id, state)

      :error ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => jsonrpc_id,
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => "Tool not registered: #{inspect(tool_name)}"}
            ],
            "isError" => true
          }
        }

        {Control.mcp_success_response(request_id, response),
         %{state | errors: ["unknown tool: #{tool_name}" | state.errors]}}
    end
  end

  defp handle_jsonrpc(request_id, msg, %State{} = state) do
    method = Map.get(msg, "method", "<unknown>")
    jsonrpc_id = Map.get(msg, "id")

    response = %{
      "jsonrpc" => "2.0",
      "id" => jsonrpc_id,
      "error" => %{"code" => -32_601, "message" => "Method not supported: #{method}"}
    }

    {Control.mcp_success_response(request_id, response), state}
  end

  defp invoke_tool(%ReqLLM.Tool{} = tool, jsonrpc_id, arguments, request_id, state) do
    try do
      case ReqLLM.Tool.execute(tool, normalize_args(arguments)) do
        {:ok, result} ->
          ok_response(request_id, jsonrpc_id, result, state)

        {:error, reason} ->
          error_response(request_id, jsonrpc_id, reason, tool.name, state)
      end
    rescue
      e ->
        error_response(request_id, jsonrpc_id, Exception.message(e), tool.name, state)
    end
  end

  defp ok_response(request_id, jsonrpc_id, result, state) do
    text =
      cond do
        is_binary(result) -> result
        true -> safe_json_encode(result)
      end

    response = %{
      "jsonrpc" => "2.0",
      "id" => jsonrpc_id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "isError" => false
      }
    }

    {Control.mcp_success_response(request_id, response), state}
  end

  defp error_response(request_id, jsonrpc_id, reason, tool_name, state) do
    text =
      cond do
        is_binary(reason) -> reason
        true -> inspect(reason)
      end

    response = %{
      "jsonrpc" => "2.0",
      "id" => jsonrpc_id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "isError" => true
      }
    }

    {Control.mcp_success_response(request_id, response),
     %{state | errors: ["#{tool_name}: #{text}" | state.errors]}}
  end

  defp tool_descriptor(%ReqLLM.Tool{} = tool) do
    json_schema = ReqLLM.Schema.to_json(tool.parameter_schema)

    %{
      "name" => tool.name,
      "description" => tool.description || "",
      "inputSchema" => json_schema
    }
  end

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_), do: %{}

  defp safe_json_encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _ -> inspect(value)
    end
  end
end
