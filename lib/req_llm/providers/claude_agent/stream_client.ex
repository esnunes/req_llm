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

  alias ReqLLM.Providers.ClaudeAgent.{CLI, Protocol}
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

    with {:ok, binary} <- CLI.resolve_binary(provider_opts),
         :ok <- CLI.verify_version(binary, provider_opts) do
      args = CLI.build_args(model, Keyword.put(provider_opts, :stream, true))
      canonical = %{"model" => CLI.build_args(model, []), "args" => args}

      http_context =
        HTTPContext.new("claude://local/cli", :post, %{
          "x-claude-cli-binary" => binary
        })

      task =
        Task.Supervisor.async_nolink(ReqLLM.TaskSupervisor, fn ->
          run_stream(binary, args, provider_opts, context, stream_server_pid)
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

  defp run_stream(binary, args, provider_opts, context, stream_server_pid) do
    port = CLI.open_port(binary, args, provider_opts)
    monitor_ref = Process.monitor(stream_server_pid)
    timeout = Keyword.get(provider_opts, :cli_timeout, 300_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    initial_state = %{buffer: "", finished?: false, monitor_ref: monitor_ref}

    try do
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
          state = forward_lines(stream_server_pid, lines, state)
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

  defp forward_lines(_pid, [], state), do: state

  defp forward_lines(pid, [line | rest], state) do
    case classify(line) do
      :skip ->
        forward_lines(pid, rest, state)

      {:terminal, _ev} ->
        safe_event(pid, :done)
        %{state | finished?: true}

      {:forward, line_to_emit} ->
        chunk = sse_chunk(line_to_emit)
        safe_event(pid, {:data, chunk})
        forward_lines(pid, rest, state)
    end
  end

  defp classify(""), do: :skip

  defp classify(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "stream_event", "event" => event}} when is_map(event) ->
        {:forward, Jason.encode!(event)}

      {:ok, %{"type" => "result"} = _ev} ->
        {:terminal, line}

      {:ok, _} ->
        :skip

      _ ->
        :skip
    end
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
