defmodule ReqLLM.Providers.ClaudeAgent.StreamClient do
  @moduledoc """
  StreamServer transport that owns a Claude Code CLI subprocess.

  Mirrors the shape of `ReqLLM.Streaming.FinchClient` /
  `ReqLLM.Streaming.WebSocketClient` so it can plug into the existing
  `StreamServer` transport dispatch.

  The task spawns a `claude` Port, writes the initial user event, and
  forwards each stream-json line to the StreamServer as if it were an
  HTTP chunk. The `:claude_agent` provider's `decode_stream_event/3`
  callback (which delegates to the Anthropic decoder) then translates
  those events into `StreamChunk`s.
  """

  alias ReqLLM.Providers.ClaudeAgent.{CLI, Control, Protocol, Tools}
  alias ReqLLM.Streaming.Fixtures.HTTPContext
  alias ReqLLM.StreamServer

  require Logger

  @doc """
  Start the streaming task. Returns `{:ok, task_pid, http_context, canonical_json}`.
  """
  @spec start_stream(
          module(),
          LLMDB.Model.t(),
          ReqLLM.Context.t(),
          keyword(),
          pid(),
          atom()
        ) :: {:ok, pid(), HTTPContext.t(), map()} | {:error, term()}
  def start_stream(_provider_mod, model, context, opts, stream_server_pid, _finch_name \\ nil) do
    provider_opts = provider_opts_from(opts)
    tools_opts = Keyword.put_new(provider_opts, :tools, Keyword.get(opts, :tools))

    with {:ok, binary} <- CLI.resolve_binary(provider_opts),
         :ok <- CLI.verify_version(binary, provider_opts),
         {:ok, tools_state} <- Tools.prepare(tools_opts) do
      args = CLI.build_args(model, Keyword.put(provider_opts, :stream, true))
      canonical = %{"model" => CLI.build_args(model, []), "args" => args}

      http_context =
        HTTPContext.new("claude://local/cli", :post, %{
          "x-claude-cli-binary" => binary
        })

      task =
        Task.Supervisor.async_nolink(ReqLLM.TaskSupervisor, fn ->
          run_stream(binary, args, provider_opts, context, stream_server_pid, tools_state)
        end)

      {:ok, task.pid, http_context, canonical}
    end
  end

  defp provider_opts_from(opts) do
    case Keyword.fetch(opts, :provider_options) do
      {:ok, list} when is_list(list) -> list
      _ -> opts
    end
  end

  defp run_stream(binary, args, provider_opts, context, stream_server_pid, tools_state) do
    port = CLI.open_port(binary, args, provider_opts)
    monitor_ref = Process.monitor(stream_server_pid)
    timeout = Keyword.get(provider_opts, :cli_timeout, 300_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    initial_state = %{
      buffer: "",
      finished?: false,
      monitor_ref: monitor_ref,
      tools_state: tools_state
    }

    try do
      if Tools.advertise?(tools_state) do
        {_id, init_event} =
          Control.initialize_request(Control.new_request_id(), [Tools.server_name()])

        _ = CLI.write_event(port, init_event)
      end

      _ = CLI.write_event(port, Protocol.encode_user_event(context))
      safe_event(stream_server_pid, {:status, 200})
      safe_event(stream_server_pid, {:headers, [{"content-type", "text/event-stream"}]})

      do_pump(port, initial_state, stream_server_pid, deadline)
    after
      Process.demonitor(monitor_ref, [:flush])
      CLI.close_port(port)
    end
  end

  defp do_pump(_port, %{finished?: true}, _stream_server_pid, _deadline) do
    :ok
  end

  defp do_pump(port, state, stream_server_pid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      safe_event(stream_server_pid, {:error, :timeout})
      :timeout
    else
      monitor_ref = state.monitor_ref

      receive do
        {^port, {:data, chunk}} ->
          {state, lines} = accumulate(state, chunk)
          state = forward_lines(port, stream_server_pid, lines, state)
          do_pump(port, state, stream_server_pid, deadline)

        {^port, {:exit_status, status}} ->
          if state.finished? do
            :ok
          else
            event = if status == 0, do: :done, else: {:error, {:exit, status}}
            safe_event(stream_server_pid, event)
          end

          :ok

        {:DOWN, ^monitor_ref, :process, ^stream_server_pid, _reason} ->
          :stream_server_down
      after
        remaining ->
          safe_event(stream_server_pid, {:error, :timeout})
          :timeout
      end
    end
  end

  defp accumulate(state, chunk) do
    combined = state.buffer <> chunk
    parts = String.split(combined, "\n")
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {%{state | buffer: tail}, complete}
  end

  defp forward_lines(_port, _pid, [], state), do: state

  defp forward_lines(port, pid, [line | rest], state) do
    case classify(line) do
      :skip ->
        forward_lines(port, pid, rest, state)

      {:terminal, _ev} ->
        safe_event(pid, :done)
        %{state | finished?: true}

      {:forward, line_to_emit} ->
        chunk = sse_chunk(line_to_emit)
        safe_event(pid, {:data, chunk})
        forward_lines(port, pid, rest, state)

      {:control_request, subtype, request_id, payload} ->
        new_state = handle_control_request(port, state, subtype, request_id, payload)
        forward_lines(port, pid, rest, new_state)

      {:control_response, _subtype, _id, _payload} ->
        forward_lines(port, pid, rest, state)
    end
  end

  defp classify(""), do: :skip

  defp classify(line) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        case Control.classify(decoded) do
          {:request, subtype, request_id, payload} ->
            {:control_request, subtype, request_id, payload}

          {:response, subtype, request_id, payload} ->
            {:control_response, subtype, request_id, payload}

          :not_control ->
            classify_stream_line(decoded, line)
        end

      _ ->
        :skip
    end
  end

  defp classify_stream_line(%{"type" => "stream_event", "event" => event}, _line)
       when is_map(event),
       do: {:forward, Jason.encode!(event)}

  defp classify_stream_line(%{"type" => "result"}, line), do: {:terminal, line}
  defp classify_stream_line(_, _line), do: :skip

  defp handle_control_request(port, state, "mcp_message", request_id, payload) do
    case state.tools_state do
      %Tools.State{} = tools ->
        {response, new_tools} = Tools.dispatch_mcp(request_id, payload, tools)
        _ = CLI.write_event(port, response)
        %{state | tools_state: new_tools}

      _ ->
        _ =
          CLI.write_event(
            port,
            Control.mcp_error_response(request_id, "No tools registered")
          )

        state
    end
  end

  defp handle_control_request(port, state, _subtype, request_id, _payload) do
    _ =
      CLI.write_event(
        port,
        Control.mcp_error_response(request_id, "Control subtype not implemented")
      )

    state
  end

  defp sse_chunk(json_line) do
    "data: " <> json_line <> "\n\n"
  end

  defp safe_event(pid, event) do
    StreamServer.http_event(pid, event)
  catch
    :exit, _ -> :ok
  end
end
