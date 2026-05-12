defmodule ReqLLM.Providers.ClaudeAgent.ReqAdapter do
  @moduledoc """
  Custom Req adapter for the `:claude_agent` provider.

  Instead of making an HTTP request, this adapter spawns the `claude` CLI,
  writes the conversation as a stream-json event, reads stream-json events
  back, and assembles a synthetic `%Req.Response{}` that the rest of the
  ReqLLM pipeline (decode/usage/telemetry) can consume unchanged.
  """

  alias ReqLLM.Providers.ClaudeAgent.{CLI, Protocol}

  @doc """
  Adapter entry point. Returns `{request, response_or_error}` per the Req
  adapter protocol.
  """
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = req) do
    provider_opts = Req.Request.get_private(req, :req_llm_provider_opts) || []
    model = Req.Request.get_private(req, :req_llm_model)

    context = req.options[:context]
    timeout = Keyword.get(provider_opts, :cli_timeout, 120_000)

    with {:ok, binary} <- CLI.resolve_binary(provider_opts),
         :ok <- CLI.verify_version(binary, provider_opts),
         args <- CLI.build_args(model, provider_opts) do
      port = CLI.open_port(binary, args, provider_opts)

      try do
        CLI.write_event(port, Protocol.encode_user_event(context))

        case CLI.read_to_terminal(port, timeout) do
          {:ok, %{result: result, events: events} = state} ->
            init_event = find_init_event(events)
            body = Protocol.synthesize_response_body(events, result, init_event)
            status = status_for_result(result)

            response = %Req.Response{
              status: status,
              headers: build_headers(state, binary),
              body: body,
              private: %{}
            }

            {req, response}

          {:error, :timeout} ->
            {req,
             ReqLLM.Error.API.Request.exception(
               reason: :timeout,
               status: 504
             )}

          {:error, {:exit, code, diagnostic}} ->
            {req,
             ReqLLM.Error.API.Request.exception(
               reason:
                 "Claude Code CLI exited with status #{code}." <>
                   if(diagnostic == "", do: "", else: " stderr: " <> diagnostic),
               status: error_status_for_exit(code),
               response_body: diagnostic
             )}

          {:error, other} ->
            {req,
             ReqLLM.Error.API.Response.exception(
               reason: "Claude Code CLI protocol error: #{inspect(other)}"
             )}
        end
      after
        CLI.close_port(port)
      end
    else
      {:error, %{} = err} -> {req, err}
      {:error, other} -> {req, ReqLLM.Error.Unknown.Unknown.exception(error: other)}
    end
  end

  defp find_init_event(events) do
    Enum.find(events, fn
      %{"type" => "system", "subtype" => "init"} -> true
      _ -> false
    end)
  end

  defp status_for_result(nil), do: 200
  defp status_for_result(%{"is_error" => true}), do: 500
  defp status_for_result(%{"subtype" => "error"}), do: 500
  defp status_for_result(_), do: 200

  defp error_status_for_exit(1), do: 401
  defp error_status_for_exit(_), do: 500

  defp build_headers(state, binary) do
    sid = state.session_id

    [
      {"x-claude-cli-binary", binary},
      {"x-claude-agent-session-id", sid || ""},
      {"x-claude-agent-api-key-source", state.api_key_source || ""}
    ]
  end
end
