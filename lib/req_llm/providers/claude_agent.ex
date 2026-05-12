defmodule ReqLLM.Providers.ClaudeAgent do
  @moduledoc """
  Provider implementation for Anthropic Claude routed through the locally
  installed Claude Code CLI (`claude` binary).

  This provider consumes Anthropic Claude through the user's Claude subscription
  by invoking the local CLI rather than the HTTP `/v1/messages` endpoint. The
  CLI is treated as the transport: each call spawns a `claude --print
  --input-format stream-json --output-format stream-json --verbose ...`
  subprocess, the request is delivered over stdin, and stream-json events are
  read from stdout.

  ## Usage

      iex> ReqLLM.generate_text("claude_agent:claude-sonnet-4-5-20250929", "Hello!")
      {:ok, response}

  ## Authentication

  Authentication is handled out-of-band by the CLI itself. Run `claude auth
  login` once on the host; ReqLLM never touches credentials.

  ## Model Catalog

  Models are looked up in the standard Anthropic catalog (the same entries
  used by `:anthropic`). The provider id is rewritten when the model struct is
  returned, but cost/capabilities/ids come from the shared registry.
  """

  use ReqLLM.Provider,
    id: :claude_agent,
    default_base_url: "claude://local"

  alias ReqLLM.Providers.ClaudeAgent.{CLI, ReqAdapter, Usage}

  @provider_schema [
    allowed_tools: [
      type: {:or, [{:list, :string}, {:in, [:default, :none]}]},
      default: :default,
      doc: """
      Built-in Claude Code tools the CLI may invoke. Accepts:

      - `:default` (no `--allowedTools` flag — CLI default applies)
      - `:none` (disable all built-in tools via `--allowedTools ""`)
      - list of strings (e.g. `["Read", "Bash(git *)"]`)
      """
    ],
    disallowed_tools: [
      type: {:list, :string},
      doc: "Built-in tools to forbid (`--disallowedTools` argument)."
    ],
    session_id: [
      type: :string,
      doc: """
      Existing CLI session UUID to resume via `--resume`. Must be a session
      identifier the CLI assigned in a prior turn; arbitrary UUIDs you generate
      yourself will not bring back any prior context.
      """
    ],
    previous_response_id: [
      type: :string,
      doc: "Alias for :session_id (parity with the OpenAI Codex provider)."
    ],
    claude_binary: [
      type: :string,
      doc: """
      Absolute path to the `claude` executable. Defaults to
      `System.find_executable("claude")` at request time.
      """
    ],
    cli_timeout: [
      type: :pos_integer,
      default: 120_000,
      doc: "Hard timeout (ms) before the CLI subprocess is killed."
    ],
    include_partial_messages: [
      type: :boolean,
      doc: """
      Pass `--include-partial-messages` so the CLI emits token-level
      `stream_event` deltas. Defaults to `true` for streaming calls and
      `false` otherwise.
      """
    ],
    permission_mode: [
      type: {:in, [:default, :accept_edits, :plan, :bypass_permissions]},
      default: :default,
      doc: "Forwarded as `--permission-mode` when not `:default`."
    ],
    cli_env: [
      type: {:list, {:tuple, [:string, :string]}},
      doc: "Extra environment variables to inject into the subprocess."
    ],
    minimum_cli_version: [
      type: :string,
      doc: "Override the minimum supported CLI version. Defaults to 2.1.119."
    ]
  ]

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- validate_model_provider(model),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context),
         {:ok, processed_opts} <- resolve_session_alias(processed_opts) do
      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options, :tools, :tool_choice]

      request =
        Req.new(
          base_url: "claude://local",
          url: "/cli",
          method: :post,
          receive_timeout:
            Keyword.get(processed_opts, :cli_timeout, default_cli_timeout(processed_opts))
        )
        |> Req.Request.register_options(req_keys ++ [:claude_agent_metadata])
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++ [model: get_api_model_id(model)]
        )
        |> Req.Request.put_private(:req_llm_model, model)
        |> Req.Request.put_private(:req_llm_provider_opts, processed_opts)
        |> Map.put(:adapter, &ReqAdapter.run/1)
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    case ReqLLM.Tool.new(
           name: "structured_output",
           description: "Emit a JSON object matching the provided schema.",
           parameter_schema: ReqLLM.Schema.to_json(compiled_schema.schema),
           strict: true,
           callback: fn args -> {:ok, args} end
         ) do
      {:ok, tool} ->
        opts
        |> Keyword.update(:tools, [tool], fn existing -> [tool | existing] end)
        |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})
        |> Keyword.put(:operation, :object)
        |> then(&prepare_request(:chat, model_spec, prompt, &1))

      {:error, _} = err ->
        err
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: [:chat, :object]"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model, _user_opts) do
    if model.provider != :claude_agent do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    request
    |> Req.Request.put_private(:req_llm_model, model)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, [])
  end

  @impl ReqLLM.Provider
  def encode_body(request), do: request

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    case response.status do
      status when status in 200..299 ->
        decode_success_response(request, response)

      status ->
        decode_error_response(request, response, status)
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model), do: Usage.extract(body, model)

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    ReqLLM.Providers.Anthropic.Response.decode_stream_event(event, anthropic_model_view(model))
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    ReqLLM.Providers.Anthropic.Response.decode_stream_event(
      event,
      anthropic_model_view(model),
      state
    )
  end

  @impl ReqLLM.Provider
  def init_stream_state(_model), do: ReqLLM.Providers.Anthropic.Response.init_stream_state()

  @impl ReqLLM.Provider
  def flush_stream_state(model, state) do
    ReqLLM.Providers.Anthropic.Response.flush_stream_state(anthropic_model_view(model), state)
  end

  @impl ReqLLM.Provider
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     ReqLLM.Error.API.Request.exception(
       reason:
         "ClaudeAgent uses a Port transport (provider_options[:stream_transport] = :port). Set :stream_transport via StreamServer, not Finch."
     )}
  end

  @impl ReqLLM.Provider
  def stream_transport(_model, _opts), do: :port

  defp anthropic_model_view(%LLMDB.Model{} = model), do: %{model | provider: :anthropic}
  defp anthropic_model_view(other), do: other

  @doc """
  Resolve the underlying API model id used on the CLI's `--model` flag.

  Falls back to the model's `provider_model_id` if set, otherwise the `id`.
  """
  @spec get_api_model_id(LLMDB.Model.t()) :: String.t()
  def get_api_model_id(%LLMDB.Model{provider_model_id: api_id}) when is_binary(api_id), do: api_id
  def get_api_model_id(%LLMDB.Model{id: id}) when is_binary(id), do: id

  @doc """
  Build the CLI argument list from a request's stored provider options.
  Exposed so the streaming transport can reuse the same shape.
  """
  @spec cli_args(LLMDB.Model.t(), keyword(), keyword()) :: [String.t()]
  def cli_args(model, opts, extra_args \\ []) do
    CLI.build_args(model, opts, extra_args)
  end

  defp validate_model_provider(%LLMDB.Model{provider: :claude_agent}), do: :ok

  defp validate_model_provider(%LLMDB.Model{provider: provider}) do
    {:error, ReqLLM.Error.Invalid.Provider.exception(provider: provider)}
  end

  defp resolve_session_alias(opts) do
    sid = Keyword.get(opts, :session_id)
    prid = Keyword.get(opts, :previous_response_id)

    cond do
      is_binary(sid) and is_binary(prid) and sid != prid ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             "claude_agent provider: :session_id and :previous_response_id are aliases. Provide only one."
         )}

      is_binary(prid) and is_nil(sid) ->
        {:ok, Keyword.put(opts, :session_id, prid)}

      true ->
        {:ok, opts}
    end
  end

  defp default_cli_timeout(opts) do
    Keyword.get(opts, :cli_timeout, 120_000)
  end

  defp decode_success_response(request, response) do
    body = response.body || %{}
    model = Req.Request.get_private(request, :req_llm_model)

    case ReqLLM.Providers.ClaudeAgent.Response.assemble(body, model, request.options) do
      {:ok, response_struct} ->
        {request, %{response | body: response_struct}}

      {:error, reason} ->
        error =
          ReqLLM.Error.API.Response.exception(
            reason: "Failed to decode Claude Code CLI response: #{inspect(reason)}",
            response_body: body
          )

        {request, error}
    end
  end

  defp decode_error_response(request, response, status) do
    reason =
      case response.body do
        %{"error" => err} when is_binary(err) -> err
        %{"error" => %{"message" => msg}} when is_binary(msg) -> msg
        %{"error" => err} -> inspect(err)
        other -> inspect(other)
      end

    error =
      ReqLLM.Error.API.Response.exception(
        reason: reason,
        response_body: response.body,
        status: status
      )

    {request, error}
  end
end
