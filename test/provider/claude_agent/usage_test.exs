defmodule ReqLLM.Providers.ClaudeAgent.UsageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.ClaudeAgent
  alias ReqLLM.Providers.ClaudeAgent.Usage

  describe "extract/2" do
    test "pulls the Anthropic-shaped usage map from a synthesized response body" do
      body = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_creation_input_tokens" => 200,
          "cache_read_input_tokens" => 400
        }
      }

      assert {:ok, usage} = Usage.extract(body, %LLMDB.Model{id: "x", provider: :claude_agent})
      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 50
      assert usage["cache_creation_input_tokens"] == 200
      assert usage["cache_read_input_tokens"] == 400
    end

    test "falls back to cli_reported_cost_usd when no usage map is present" do
      body = %{"_claude_agent" => %{"cli_reported_cost_usd" => 0.0042}}

      assert {:ok, %{"cli_reported_cost_usd" => 0.0042}} =
               Usage.extract(body, %LLMDB.Model{id: "x", provider: :claude_agent})
    end

    test "returns an error when nothing usage-like is in the body" do
      assert {:error, _} =
               Usage.extract(%{"foo" => "bar"}, %LLMDB.Model{id: "x", provider: :claude_agent})
    end
  end

  describe "extract_usage/2 callback" do
    test "delegates to Usage.extract/2" do
      body = %{"usage" => %{"input_tokens" => 1, "output_tokens" => 2}}

      assert {:ok, %{"input_tokens" => 1, "output_tokens" => 2}} =
               ClaudeAgent.extract_usage(body, %LLMDB.Model{id: "x", provider: :claude_agent})
    end
  end
end
