defmodule ReqLLM.Providers.ClaudeAgent.StreamDecodeTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.ClaudeAgent

  @model_id "claude_agent:claude-sonnet-4-5-20250929"

  describe "stream_text/3 via the port transport" do
    test "consumes streaming text via the fake CLI" do
      ClaudeAgent.with_fixture("streaming_text", fn ->
        {:ok, stream_response} =
          ReqLLM.stream_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        text_chunks =
          stream_response.stream
          |> Stream.filter(&(&1.type == :content))
          |> Enum.map(& &1.text)
          |> Enum.to_list()

        joined = Enum.join(text_chunks)
        assert joined =~ "Hello"
        assert joined =~ "world"
      end)
    end

    test "surfaces CLI metadata (session_id, cost, terminal_reason, modelUsage) on the response" do
      ClaudeAgent.with_fixture("streaming_text_with_meta", fn ->
        {:ok, stream_response} =
          ReqLLM.stream_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
        meta = response.provider_meta || %{}

        assert meta[:cli_session_id] == "sess-meta-9"
        assert meta[:cli_reported_cost_usd] == 0.0042
        assert meta[:cli_terminal_reason] == "completed"
        assert meta[:cli_api_key_source] == "none"
        assert is_map(meta[:cli_model_usage_breakdown])
        assert response.finish_reason == :stop

        usage = response.usage || %{}
        assert usage[:input_tokens] == 4
        assert usage[:output_tokens] == 2
      end)
    end
  end
end
