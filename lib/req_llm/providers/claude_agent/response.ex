defmodule ReqLLM.Providers.ClaudeAgent.Response do
  @moduledoc """
  Assemble a `ReqLLM.Response` from the synthetic Anthropic-shaped body
  produced by the CLI adapter.

  This module is intentionally thin: it delegates to the Anthropic decoder
  for the content blocks, then layers Claude Code-specific metadata
  (session id, CLI-reported cost, MCP server statuses, permission denials)
  on top.
  """

  alias ReqLLM.Providers.Anthropic.Response, as: AnthropicResponse

  @spec assemble(map(), LLMDB.Model.t() | map(), keyword() | map()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def assemble(body, model, _opts \\ [])

  def assemble(body, model, _opts) when is_map(body) do
    case AnthropicResponse.decode_response(strip_extra(body), to_model(model)) do
      {:ok, %ReqLLM.Response{} = response} ->
        extras = Map.get(body, "_claude_agent", %{})

        provider_meta =
          response.provider_meta
          |> Map.put(:claude_agent, extras)
          |> maybe_put(:cli_reported_cost_usd, Map.get(extras, "cli_reported_cost_usd"))
          |> maybe_put(:cli_session_id, Map.get(extras, "session_id"))
          |> maybe_put(:cli_terminal_reason, Map.get(extras, "terminal_reason"))
          |> maybe_put(:cli_api_key_source, Map.get(extras, "api_key_source"))
          |> maybe_put(:cli_permission_denials, Map.get(extras, "permission_denials"))
          |> maybe_put(:cli_model_usage_breakdown, Map.get(extras, "model_usage_breakdown"))
          |> maybe_put(:cli_mcp_servers, Map.get(extras, "mcp_servers"))

        {:ok, %{response | provider_meta: provider_meta}}

      {:error, _} = err ->
        err
    end
  end

  def assemble(_body, _model, _opts), do: {:error, :invalid_body}

  defp strip_extra(body), do: Map.delete(body, "_claude_agent")

  defp to_model(%LLMDB.Model{} = m), do: m

  defp to_model(map) when is_map(map) do
    %LLMDB.Model{
      id: Map.get(map, :id) || Map.get(map, "id") || "claude-unknown",
      provider: :anthropic,
      provider_model_id: Map.get(map, :provider_model_id) || Map.get(map, "id")
    }
  end

  defp to_model(_), do: %LLMDB.Model{id: "claude-unknown", provider: :anthropic}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
