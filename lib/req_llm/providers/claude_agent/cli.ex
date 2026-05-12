defmodule ReqLLM.Providers.ClaudeAgent.CLI do
  @moduledoc """
  Subprocess lifecycle for the Claude Code CLI.

  Responsibilities:

  - Resolve the `claude` binary path (request override or `System.find_executable/1`).
  - Verify the installed version satisfies the pinned minimum.
  - Build the command-line argument list from provider options.
  - Open a `Port` over the binary's stdin/stdout and demultiplex incoming
    lines into stream-json events vs. diagnostic noise.
  - Write JSON events back to stdin.
  - Tear the port down on completion, timeout, or caller cancellation.
  """

  @default_minimum_version "2.1.119"
  @diagnostic_buffer_limit 64 * 1024
  @version_cache_key {__MODULE__, :version_cache}

  @doc """
  Resolve the binary path the request should invoke.
  """
  @spec resolve_binary(keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def resolve_binary(opts) do
    case Keyword.get(opts, :claude_binary) || System.find_executable("claude") do
      nil ->
        {:error,
         ReqLLM.Error.Invalid.Capability.exception(
           message:
             "Claude Code CLI binary `claude` not found on $PATH. Install it (https://claude.com/code) or set provider_options[:claude_binary]."
         )}

      path when is_binary(path) ->
        case File.stat(path) do
          {:ok, _} ->
            {:ok, path}

          {:error, reason} ->
            {:error,
             ReqLLM.Error.Invalid.Capability.exception(
               message: "Configured claude_binary is not accessible (#{inspect(reason)}): #{path}"
             )}
        end
    end
  end

  @doc """
  Check the binary's version against the pinned minimum. Caches per binary
  path under `:persistent_term`. Returns `:ok` or a typed error.
  """
  @spec verify_version(String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def verify_version(binary, opts) do
    minimum = Keyword.get(opts, :minimum_cli_version, @default_minimum_version)

    case cached_version(binary) do
      {:ok, %Version{} = version} ->
        compare_version(version, minimum)

      {:error, reason} ->
        {:error,
         ReqLLM.Error.Invalid.Capability.exception(
           message:
             "Unable to determine Claude Code CLI version for #{binary}: #{inspect(reason)}"
         )}
    end
  end

  @doc """
  Invalidate the cached version lookup. Useful in tests or when the user
  upgrades the CLI without restarting the BEAM node.
  """
  @spec invalidate_version_cache!() :: :ok
  def invalidate_version_cache! do
    :persistent_term.erase(@version_cache_key)
    :ok
  end

  @doc """
  Build the argument vector passed to `claude` for one call.

  Always includes:
    `--print --input-format stream-json --output-format stream-json --verbose --model <id>`

  Optionally adds: `--resume`, `--allowedTools`, `--disallowedTools`,
  `--permission-mode`, `--include-partial-messages`, plus any extras.
  """
  @spec build_args(LLMDB.Model.t() | map(), keyword(), [String.t()]) :: [String.t()]
  def build_args(model, opts, extra_args \\ []) do
    base = [
      "--print",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      api_model_id(model)
    ]

    base
    |> maybe_add_resume(opts)
    |> maybe_add_allowed_tools(opts)
    |> maybe_add_disallowed_tools(opts)
    |> maybe_add_permission_mode(opts)
    |> maybe_add_partial_messages(opts)
    |> Kernel.++(List.wrap(extra_args))
  end

  @doc """
  Open a port over the binary. Returns the port. The caller owns it and must
  close it.
  """
  @spec open_port(String.t(), [String.t()], keyword()) :: port()
  def open_port(binary, args, opts \\ []) do
    env =
      opts
      |> Keyword.get(:cli_env, [])
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port_opts =
      [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, args}
      ] ++ if env == [], do: [], else: [{:env, env}]

    Port.open({:spawn_executable, binary}, port_opts)
  end

  @doc """
  Write a single JSON event followed by a newline. Returns `:ok` on success or
  `{:error, :port_closed}` when the port has already exited.
  """
  @spec write_event(port(), map()) :: :ok | {:error, :port_closed}
  def write_event(port, event) when is_map(event) do
    line = Jason.encode!(event)

    try do
      Port.command(port, line <> "\n")
      :ok
    rescue
      ArgumentError -> {:error, :port_closed}
    end
  end

  @doc """
  Read from the port until either a terminal `result` event arrives or the
  port exits. Returns a map describing the stream collected events, the
  terminal result (if any), any diagnostic buffer, and the exit status.
  """
  @spec read_to_terminal(port(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def read_to_terminal(port, timeout_ms) do
    deadline = monotonic_deadline(timeout_ms)

    state = %{
      buffer: "",
      events: [],
      result: nil,
      diagnostic: "",
      diagnostic_truncated?: false,
      session_id: nil,
      api_key_source: nil,
      permission_denials: [],
      rate_limit: nil,
      mcp_servers: [],
      exit_status: nil
    }

    do_read(port, state, deadline)
  end

  defp do_read(port, state, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      safe_close(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          {state, lines} = accumulate(state, chunk)

          case process_lines(state, lines) do
            {:cont, state} -> do_read(port, state, deadline)
            {:done, state} -> {:ok, Map.update!(state, :events, &Enum.reverse/1)}
            {:error, _} = err -> err
          end

        {^port, {:exit_status, status}} ->
          state = %{state | exit_status: status}

          case state do
            %{result: nil} ->
              {:error, {:exit, status, surface_diagnostic(state)}}

            %{result: _} ->
              {:ok, Map.update!(state, :events, &Enum.reverse/1)}
          end
      after
        remaining ->
          safe_close(port)
          {:error, :timeout}
      end
    end
  end

  @doc false
  def close_port(port), do: safe_close(port)

  # --- internal ---

  defp accumulate(state, chunk) do
    combined = state.buffer <> chunk
    parts = String.split(combined, "\n")
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {%{state | buffer: tail}, complete}
  end

  defp process_lines(state, []), do: {:cont, state}

  defp process_lines(state, [line | rest]) do
    case classify_line(line) do
      :ignore ->
        process_lines(state, rest)

      {:event, event} ->
        new_state = handle_event(state, event)

        if new_state.result != nil do
          {:done, new_state}
        else
          process_lines(new_state, rest)
        end

      {:diagnostic, line} ->
        process_lines(append_diagnostic(state, line), rest)
    end
  end

  defp classify_line(""), do: :ignore

  defp classify_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event}
      when is_binary(type) and
             type in [
               "system",
               "assistant",
               "user",
               "stream_event",
               "rate_limit_event",
               "result"
             ] ->
        {:event, event}

      _ ->
        {:diagnostic, line}
    end
  end

  defp handle_event(state, event) do
    state = %{state | events: [event | state.events]}

    case event do
      %{"type" => "system", "subtype" => "init"} = ev ->
        %{
          state
          | session_id: ev["session_id"] || state.session_id,
            api_key_source: ev["apiKeySource"] || state.api_key_source,
            mcp_servers: ev["mcp_servers"] || state.mcp_servers
        }

      %{"type" => "rate_limit_event"} = ev ->
        %{state | rate_limit: ev["rate_limit_info"] || state.rate_limit}

      %{"type" => "result"} = ev ->
        %{
          state
          | result: ev,
            permission_denials: ev["permission_denials"] || state.permission_denials,
            session_id: ev["session_id"] || state.session_id
        }

      _ ->
        state
    end
  end

  defp append_diagnostic(state, line) do
    addition = line <> "\n"
    next = state.diagnostic <> addition

    if byte_size(next) > @diagnostic_buffer_limit do
      tail =
        binary_part(next, byte_size(next) - @diagnostic_buffer_limit, @diagnostic_buffer_limit)

      %{state | diagnostic: tail, diagnostic_truncated?: true}
    else
      %{state | diagnostic: next}
    end
  end

  defp surface_diagnostic(%{diagnostic: diag, diagnostic_truncated?: true}) do
    "[diagnostic truncated; showing the last 64KB]\n" <> diag
  end

  defp surface_diagnostic(%{diagnostic: diag}), do: diag

  defp safe_close(port) do
    if Port.info(port) != nil do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp monotonic_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp cached_version(binary) do
    cache = :persistent_term.get(@version_cache_key, %{})

    case Map.fetch(cache, binary) do
      {:ok, entry} ->
        entry

      :error ->
        entry = lookup_version(binary)
        :persistent_term.put(@version_cache_key, Map.put(cache, binary, entry))
        entry
    end
  end

  defp lookup_version(binary) do
    try do
      case System.cmd(binary, ["--version"], stderr_to_stdout: true) do
        {output, 0} -> parse_version(output)
        {output, code} -> {:error, {:exit, code, output}}
      end
    rescue
      e -> {:error, e}
    end
  end

  defp parse_version(output) do
    output
    |> String.split(~r/\s+/)
    |> Enum.find_value(fn token ->
      case Version.parse(String.trim(token)) do
        {:ok, version} -> version
        :error -> nil
      end
    end)
    |> case do
      %Version{} = version -> {:ok, version}
      nil -> {:error, {:unparseable_version, output}}
    end
  end

  defp compare_version(%Version{} = found, minimum_string) when is_binary(minimum_string) do
    case Version.parse(minimum_string) do
      {:ok, minimum} ->
        if Version.compare(found, minimum) == :lt do
          {:error,
           ReqLLM.Error.Invalid.Capability.exception(
             message:
               "Claude Code CLI version #{found} is older than required #{minimum}. Run `claude --version` and upgrade."
           )}
        else
          :ok
        end

      :error ->
        {:error,
         ReqLLM.Error.Invalid.Capability.exception(
           message: "Invalid minimum_cli_version override: #{minimum_string}"
         )}
    end
  end

  defp maybe_add_resume(args, opts) do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" -> args ++ ["--resume", sid]
      _ -> args
    end
  end

  defp maybe_add_allowed_tools(args, opts) do
    case Keyword.get(opts, :allowed_tools, :default) do
      :default -> args
      :none -> args ++ ["--allowedTools", ""]
      list when is_list(list) -> args ++ ["--allowedTools", Enum.join(list, ",")]
    end
  end

  defp maybe_add_disallowed_tools(args, opts) do
    case Keyword.get(opts, :disallowed_tools) do
      list when is_list(list) and list != [] ->
        args ++ ["--disallowedTools", Enum.join(list, ",")]

      _ ->
        args
    end
  end

  defp maybe_add_permission_mode(args, opts) do
    case Keyword.get(opts, :permission_mode, :default) do
      :default -> args
      mode when is_atom(mode) -> args ++ ["--permission-mode", Atom.to_string(mode)]
    end
  end

  defp maybe_add_partial_messages(args, opts) do
    streaming? = Keyword.get(opts, :stream, false) == true
    default = streaming?

    case Keyword.get(opts, :include_partial_messages, default) do
      true -> args ++ ["--include-partial-messages"]
      _ -> args
    end
  end

  defp api_model_id(%LLMDB.Model{provider_model_id: id}) when is_binary(id), do: id
  defp api_model_id(%LLMDB.Model{id: id}) when is_binary(id), do: id
  defp api_model_id(%{provider_model_id: id}) when is_binary(id), do: id
  defp api_model_id(%{id: id}) when is_binary(id), do: id
  defp api_model_id(other) when is_binary(other), do: other
end
