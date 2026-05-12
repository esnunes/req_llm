defmodule ReqLLM.Providers.ClaudeAgent.OptionValidationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.ClaudeAgent

  describe "provider registration" do
    test "ReqLLM.provider/1 returns the module" do
      assert {:ok, ClaudeAgent} = ReqLLM.provider(:claude_agent)
    end

    test "ReqLLM.Providers.list/0 includes :claude_agent" do
      assert :claude_agent in ReqLLM.Providers.list()
    end

    test "provider identity" do
      assert ClaudeAgent.provider_id() == :claude_agent
      assert ClaudeAgent.base_url() == "claude://local"
    end
  end

  describe "model catalog" do
    test "claude_agent model resolves through the Anthropic catalog" do
      assert {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      assert model.provider == :claude_agent
      assert model.id == "claude-sonnet-4-5-20250929"
      assert is_map(model.cost)
    end

    test "claude_agent model inherits the same cost map as anthropic" do
      {:ok, agent_model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      {:ok, http_model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      assert agent_model.cost == http_model.cost
      assert agent_model.capabilities == http_model.capabilities
    end

    test "unknown model still produces a model struct (with warning, no crash)" do
      assert {:ok, model} =
               ExUnit.CaptureIO.with_io(:stderr, fn ->
                 ReqLLM.model("claude_agent:does-not-exist-xyz")
               end)
               |> elem(0)

      assert model.provider == :claude_agent
    end
  end

  describe "operation gating" do
    test "rejects unsupported operations" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ClaudeAgent.prepare_request(
                 :embed,
                 "claude_agent:claude-sonnet-4-5-20250929",
                 "x",
                 []
               )
    end
  end

  describe "attach/3 provider guard" do
    test "raises when model provider is not :claude_agent" do
      {:ok, anthropic_model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        ClaudeAgent.attach(Req.new(url: "claude://x"), anthropic_model, [])
      end
    end
  end

  describe "session id alias resolution" do
    test "providing both :session_id and :previous_response_id is rejected" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")

      result =
        ClaudeAgent.prepare_request(:chat, model, "hi",
          provider_options: [
            session_id: "550e8400-e29b-41d4-a716-446655440000",
            previous_response_id: "different-uuid"
          ]
        )

      case result do
        {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
          assert param =~ "aliases"

        other ->
          flunk("expected Invalid.Parameter error, got: #{inspect(other)}")
      end
    end
  end

  describe "cli arg building" do
    test "default cli args include --print, --input-format, --output-format, --verbose, --model" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, [])
      assert "--print" in args
      assert "--input-format" in args
      assert "stream-json" in args
      assert "--output-format" in args
      assert "--verbose" in args
      assert "--model" in args
    end

    test "allowed_tools => list joins with comma" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, allowed_tools: ["Read", "Bash"])
      flag_idx = Enum.find_index(args, &(&1 == "--allowedTools"))
      assert flag_idx != nil
      assert Enum.at(args, flag_idx + 1) == "Read,Bash"
    end

    test "allowed_tools => :none emits empty-string flag value" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, allowed_tools: :none)
      flag_idx = Enum.find_index(args, &(&1 == "--allowedTools"))
      assert flag_idx != nil
      assert Enum.at(args, flag_idx + 1) == ""
    end

    test "allowed_tools => :default skips the flag entirely" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, allowed_tools: :default)
      refute "--allowedTools" in args
    end

    test "disallowed_tools list emits --disallowedTools" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, disallowed_tools: ["WebFetch"])
      flag_idx = Enum.find_index(args, &(&1 == "--disallowedTools"))
      assert flag_idx != nil
      assert Enum.at(args, flag_idx + 1) == "WebFetch"
    end

    test "session_id maps to --resume" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, session_id: "550e8400-e29b-41d4-a716-446655440000")
      flag_idx = Enum.find_index(args, &(&1 == "--resume"))
      assert flag_idx != nil
      assert Enum.at(args, flag_idx + 1) == "550e8400-e29b-41d4-a716-446655440000"
    end

    test "stream: true adds --include-partial-messages by default" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, stream: true)
      assert "--include-partial-messages" in args
    end

    test "stream: true with include_partial_messages: false drops the flag" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, stream: true, include_partial_messages: false)
      refute "--include-partial-messages" in args
    end

    test "permission_mode :plan emits the flag" do
      {:ok, model} = ReqLLM.model("claude_agent:claude-sonnet-4-5-20250929")
      args = ClaudeAgent.cli_args(model, permission_mode: :plan)
      flag_idx = Enum.find_index(args, &(&1 == "--permission-mode"))
      assert flag_idx != nil
      assert Enum.at(args, flag_idx + 1) == "plan"
    end
  end
end
