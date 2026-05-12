defmodule ReqLLM.Providers.ClaudeAgent.Usage do
  @moduledoc """
  Pull a normalized usage map out of the CLI's terminal `result` event
  (or the synthesized response body) so the standard usage pipeline can
  compute cost.

  The CLI surfaces an `usage` shape that is byte-compatible with the
  Anthropic Messages API, plus extras like `total_cost_usd` and a
  per-sub-model `modelUsage` breakdown. We strip the extras for the headline
  usage value and expose them via metadata.
  """

  @spec extract(map(), term()) :: {:ok, map()} | {:error, term()}
  def extract(body, _model) when is_map(body) do
    case Map.get(body, "usage") do
      usage when is_map(usage) and usage != %{} ->
        {:ok, usage}

      _ ->
        case Map.get(body, "_claude_agent") do
          %{"cli_reported_cost_usd" => cost} when not is_nil(cost) ->
            {:ok, %{"cli_reported_cost_usd" => cost}}

          _ ->
            {:error, :no_usage_found}
        end
    end
  end

  def extract(_body, _model), do: {:error, :invalid_body}
end
