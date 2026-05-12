defmodule ReqLLM.Providers.ClaudeAgent.ReqAdapter do
  @moduledoc """
  Custom Req adapter for the `:claude_agent` provider.

  Instead of making an HTTP request, this adapter spawns the `claude` CLI,
  writes the conversation as a stream-json event, reads stream-json events
  back, and assembles a synthetic `%Req.Response{}` that the rest of the
  ReqLLM pipeline (decode/usage/telemetry) can consume unchanged.
  """

  alias ReqLLM.Providers.ClaudeAgent.{CLI, Control, Protocol, Tools}

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

    tools_opts =
      provider_opts
      |> Keyword.put_new(:tools, req.options[:tools])

    with {:ok, binary} <- CLI.resolve_binary(provider_opts),
         :ok <- CLI.verify_version(binary, provider_opts),
         {:ok, tools_state} <- Tools.prepare(tools_opts),
         args <- CLI.build_args(model, provider_opts) do
      port = CLI.open_port(binary, args, provider_opts)

      try do
        if Tools.advertise?(tools_state) do
          {_id, init_event} =
            Control.initialize_request(Control.new_request_id(), [Tools.server_name()])

          _ = CLI.write_event(port, init_event)
        end

        _ = CLI.write_event(port, Protocol.encode_user_event(context))

        handle_read(req, port, timeout, tools_state, binary)
      after
        CLI.close_port(port)
      end
    else
      {:error, %{} = err} -> {req, err}
      {:error, other} -> {req, ReqLLM.Error.Unknown.Unknown.exception(error: other)}
    end
  end

  defp handle_read(req, port, timeout, tools_state, binary) do
    case CLI.read_to_terminal(port, timeout, tools_state) do
      {:ok, %{result: result, events: events} = state} ->
        init_event = find_init_event(events)
        body = Protocol.synthesize_response_body(events, result, init_event)
        status = status_for_result(result)

        response = %Req.Response{
          status: status,
          headers: build_headers(state, binary),
          body: body,
          private: %{
            tool_errors: tool_errors(state.tools_state)
          }
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
           reason: build_exit_reason(code, diagnostic),
           status: error_status_for(code, diagnostic),
           response_body: diagnostic
         )}

      {:error, other} ->
        {req,
         ReqLLM.Error.API.Response.exception(
           reason: "Claude Code CLI protocol error: #{inspect(other)}"
         )}
    end
  end

  defp tool_errors(%Tools.State{errors: errors}), do: Enum.reverse(errors)
  defp tool_errors(_), do: []

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

  defp error_status_for(0, _diagnostic), do: 502

  defp error_status_for(_code, diagnostic) when is_binary(diagnostic) do
    cond do
      auth_diagnostic?(diagnostic) -> 401
      true -> 500
    end
  end

  defp error_status_for(_code, _diagnostic), do: 500

  defp auth_diagnostic?(diagnostic) do
    lower = String.downcase(diagnostic)

    String.contains?(lower, "authentication failure") or
      String.contains?(lower, "unauthorized") or
      String.contains?(lower, "claude auth login") or
      String.contains?(lower, "not authenticated") or
      String.contains?(lower, "anthropic_api_key")
  end

  defp build_exit_reason(0, diagnostic) do
    base = "Claude Code CLI exited cleanly but never emitted a terminal `result` event."
    if diagnostic == "" or is_nil(diagnostic), do: base, else: base <> " stderr: " <> diagnostic
  end

  defp build_exit_reason(code, diagnostic) do
    base = "Claude Code CLI exited with status #{code}."
    if diagnostic == "" or is_nil(diagnostic), do: base, else: base <> " stderr: " <> diagnostic
  end

  defp build_headers(state, binary) do
    sid = state.session_id

    [
      {"x-claude-cli-binary", binary},
      {"x-claude-agent-session-id", sid || ""},
      {"x-claude-agent-api-key-source", state.api_key_source || ""}
    ]
  end
end
