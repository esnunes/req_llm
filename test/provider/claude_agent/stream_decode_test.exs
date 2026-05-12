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
  end
end
