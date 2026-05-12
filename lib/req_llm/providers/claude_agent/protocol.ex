defmodule ReqLLM.Providers.ClaudeAgent.Protocol do
  @moduledoc """
  Helpers for talking the Claude Code CLI stream-json protocol.

  - `encode_user_event/1` turns a `ReqLLM.Context` (or a plain prompt) into
    the JSON line the CLI expects on stdin as the conversation opener.
  - `extract_assistant_message/1` finds the authoritative assistant message
    out of the stream of events captured by `CLI.read_to_terminal/2`.
  - `synthesize_response_body/2` produces an Anthropic-shaped messages body
    so the rest of the ReqLLM pipeline can reuse the existing decoders.
  """

  @doc """
  Encode the conversation's opening user event from a `ReqLLM.Context`.

  We forward the entire conversation as the single user message content,
  flattening assistant turns into prior text. For full session resumption
  callers should rely on `--resume` via `:session_id` rather than replaying
  the entire history.
  """
  @spec encode_user_event(ReqLLM.Context.t() | String.t() | map()) :: map()
  def encode_user_event(%ReqLLM.Context{} = context) do
    content = encode_content_from_context(context)
    %{"type" => "user", "message" => %{"role" => "user", "content" => content}}
  end

  def encode_user_event(prompt) when is_binary(prompt) do
    %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    }
  end

  def encode_user_event(other) when is_map(other) do
    %{"type" => "user", "message" => other}
  end

  @doc """
  Pull the final assistant `message` payload out of the captured events.
  Falls back to assembling text deltas if no full assistant snapshot was
  emitted.
  """
  @spec extract_assistant_message([map()]) :: map() | nil
  def extract_assistant_message(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "assistant", "message" => message} when is_map(message) -> message
      _ -> nil
    end)
    |> case do
      nil -> assemble_from_stream_events(events)
      message -> message
    end
  end

  @doc """
  Build an Anthropic-shaped non-streaming response body from the CLI's
  collected events + terminal `result`.
  """
  @spec synthesize_response_body([map()], map() | nil, map() | nil) :: map()
  def synthesize_response_body(events, result, init_event \\ nil) do
    init_event = init_event || find_init_event(events)
    assistant = extract_assistant_message(events) || %{}

    %{
      "id" => result_field(result, "session_id") || init_event_field(init_event, "session_id"),
      "type" => "message",
      "role" => "assistant",
      "model" => result_field(result, "model") || init_event_field(init_event, "model"),
      "content" => Map.get(assistant, "content", []),
      "stop_reason" => stop_reason_from_result(result),
      "stop_sequence" => nil,
      "usage" => normalize_usage(result),
      "_claude_agent" => %{
        "session_id" =>
          result_field(result, "session_id") || init_event_field(init_event, "session_id"),
        "cli_reported_cost_usd" => result_field(result, "total_cost_usd"),
        "model_usage_breakdown" => result_field(result, "modelUsage"),
        "permission_denials" => result_field(result, "permission_denials") || [],
        "terminal_reason" => result_field(result, "terminal_reason"),
        "api_key_source" => init_event_field(init_event, "apiKeySource"),
        "mcp_servers" => init_event_field(init_event, "mcp_servers") || []
      }
    }
  end

  # --- internal ---

  defp encode_content_from_context(%ReqLLM.Context{messages: messages}) do
    Enum.flat_map(messages, &message_to_blocks/1)
  end

  defp message_to_blocks(%ReqLLM.Message{role: :system, content: content}) do
    [%{"type" => "text", "text" => "[system] " <> blocks_to_text(content)}]
  end

  defp message_to_blocks(%ReqLLM.Message{role: :user, content: content}) do
    blocks_from_content(content)
  end

  defp message_to_blocks(%ReqLLM.Message{role: :assistant, content: content}) do
    [%{"type" => "text", "text" => "[assistant] " <> blocks_to_text(content)}]
  end

  defp message_to_blocks(%ReqLLM.Message{role: :tool, content: content}) do
    [%{"type" => "text", "text" => "[tool] " <> blocks_to_text(content)}]
  end

  defp message_to_blocks(_other), do: []

  defp blocks_from_content(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp blocks_from_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) ->
        [%{"type" => "text", "text" => text}]

      part when is_map(part) ->
        case Map.get(part, :text) || Map.get(part, "text") do
          text when is_binary(text) -> [%{"type" => "text", "text" => text}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp blocks_from_content(_), do: []

  defp blocks_to_text(content) when is_binary(content), do: content

  defp blocks_to_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %ReqLLM.Message.ContentPart{type: :text, text: t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp blocks_to_text(_), do: ""

  defp assemble_from_stream_events(events) do
    blocks =
      events
      |> Enum.reduce(%{open: nil, blocks: []}, fn event, acc ->
        case event do
          %{
            "type" => "stream_event",
            "event" => %{"type" => "content_block_start", "content_block" => block}
          } ->
            %{acc | open: block}

          %{
            "type" => "stream_event",
            "event" => %{"type" => "content_block_delta", "delta" => delta}
          } ->
            %{acc | open: apply_delta(acc.open, delta)}

          %{"type" => "stream_event", "event" => %{"type" => "content_block_stop"}} ->
            case acc.open do
              nil -> acc
              block -> %{acc | open: nil, blocks: acc.blocks ++ [finalize_block(block)]}
            end

          _ ->
            acc
        end
      end)

    %{"role" => "assistant", "content" => blocks.blocks}
  end

  defp apply_delta(nil, _delta), do: nil

  defp apply_delta(block, %{"type" => "text_delta", "text" => text}) when is_binary(text) do
    Map.update(block, "text", text, fn current -> (current || "") <> text end)
  end

  defp apply_delta(block, %{"type" => "thinking_delta", "thinking" => text})
       when is_binary(text) do
    Map.update(block, "thinking", text, fn current -> (current || "") <> text end)
  end

  defp apply_delta(block, %{"type" => "input_json_delta", "partial_json" => text}) do
    Map.update(block, "_input_json", text, fn current -> (current || "") <> (text || "") end)
  end

  defp apply_delta(block, _delta), do: block

  defp finalize_block(%{"type" => "tool_use", "_input_json" => json_text} = block) do
    parsed =
      case Jason.decode(json_text || "") do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    block
    |> Map.put("input", parsed)
    |> Map.delete("_input_json")
  end

  defp finalize_block(block), do: block

  defp result_field(nil, _), do: nil
  defp result_field(map, key) when is_map(map), do: Map.get(map, key)

  defp init_event_field(nil, _), do: nil
  defp init_event_field(map, key) when is_map(map), do: Map.get(map, key)

  defp find_init_event(events) do
    Enum.find(events, fn
      %{"type" => "system", "subtype" => "init"} -> true
      _ -> false
    end)
  end

  defp stop_reason_from_result(nil), do: "end_turn"

  defp stop_reason_from_result(%{"terminal_reason" => "completed"}), do: "end_turn"
  defp stop_reason_from_result(%{"terminal_reason" => "max_tokens"}), do: "max_tokens"
  defp stop_reason_from_result(%{"terminal_reason" => "cancelled"}), do: "stop_sequence"
  defp stop_reason_from_result(%{"terminal_reason" => "incomplete"}), do: "stop_sequence"
  defp stop_reason_from_result(%{"stop_reason" => reason}) when is_binary(reason), do: reason
  defp stop_reason_from_result(_), do: "end_turn"

  defp normalize_usage(nil), do: %{}

  defp normalize_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp normalize_usage(_), do: %{}
end
