defmodule ReqLLM.Providers.ClaudeAgent.CLIInvocationTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.ClaudeAgent.CLI
  alias ReqLLM.Test.ClaudeAgent

  @model_id "claude_agent:claude-sonnet-4-5-20250929"

  describe "happy path against fake CLI" do
    test "generate_text returns assistant text" do
      ClaudeAgent.with_fixture("basic_text", fn ->
        {:ok, response} =
          ReqLLM.generate_text(@model_id, "Hello!",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        assert ReqLLM.Response.text(response) == "Hi there!"
        assert response.usage[:input_tokens] == 5
        assert response.usage[:output_tokens] == 3
        assert response.provider_meta[:cli_session_id] == "sess-abc-123"
        assert response.provider_meta[:cli_reported_cost_usd] == 0.0001
      end)
    end
  end

  describe "version detection" do
    test "rejects ancient CLI version" do
      ClaudeAgent.with_fixture("basic_text", [version: "1.0.0"], fn ->
        {:error, error} =
          ReqLLM.generate_text(@model_id, "Hello!",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        cause = capability_cause(error)
        assert %ReqLLM.Error.Invalid.Capability{} = cause
        assert cause.message =~ "older than required"
      end)
    end
  end

  describe "binary resolution" do
    test "missing binary surfaces as Invalid.Capability" do
      {:error, error} =
        ReqLLM.generate_text(@model_id, "Hi",
          provider_options: [claude_binary: "/no/such/path/never_a_binary"]
        )

      cause = capability_cause(error)
      assert %ReqLLM.Error.Invalid.Capability{} = cause
      assert cause.message =~ "not accessible" or cause.message =~ "not found"
    end
  end

  describe "auth failure" do
    test "non-zero exit surfaces stderr in an API.Request error" do
      ClaudeAgent.with_fixture("auth_failure", fn ->
        result =
          ReqLLM.generate_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        case result do
          {:error, %ReqLLM.Error.API.Request{} = err} ->
            assert err.status in [401, 500]
            assert is_binary(err.response_body)
            assert err.response_body =~ "Authentication failure"

          other ->
            flunk("expected API.Request error, got: #{inspect(other)}")
        end
      end)
    end
  end

  describe "version cache" do
    test "invalidate_version_cache!/0 forces re-detection" do
      assert :ok = CLI.invalidate_version_cache!()
    end
  end

  describe "event ordering (regression: events were double-reversed)" do
    test "captured events arrive in chronological order in the synthesized response" do
      ClaudeAgent.with_fixture("multi_event_text", fn ->
        {:ok, response} =
          ReqLLM.generate_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        text = ReqLLM.Response.text(response)

        assert text == "first piece second piece",
               "concatenated content blocks should preserve emission order, got: #{inspect(text)}"

        assert response.provider_meta[:cli_session_id] == "sess-multi-1"
      end)
    end
  end

  describe "exit-status mapping (regression: 1 → 401 conflated auth with all exit-1 errors)" do
    test "auth-style stderr maps exit 1 to 401" do
      ClaudeAgent.with_fixture("auth_failure", fn ->
        {:error, %ReqLLM.Error.API.Request{} = err} =
          ReqLLM.generate_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        assert err.status == 401
        assert err.response_body =~ "Authentication failure"
      end)
    end

    test "generic stderr maps exit 1 to 500 (not the auth-only 401)" do
      ClaudeAgent.with_fixture("generic_error", fn ->
        {:error, %ReqLLM.Error.API.Request{} = err} =
          ReqLLM.generate_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        assert err.status == 500
        assert err.response_body =~ "Internal error"
      end)
    end

    test "exit 0 with no result event produces a 502 with a descriptive reason" do
      ClaudeAgent.with_fixture("exit_0_no_result", fn ->
        {:error, %ReqLLM.Error.API.Request{} = err} =
          ReqLLM.generate_text(@model_id, "Hi",
            provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
          )

        assert err.status == 502
        assert err.reason =~ "never emitted a terminal `result` event"
      end)
    end
  end

  describe "user-defined tools gating (regression: Tools.advertise was dead code)" do
    test "passing :tools surfaces a typed NotImplemented before any subprocess work" do
      {:ok, dummy_tool} =
        ReqLLM.Tool.new(
          name: "weather",
          description: "Get weather",
          parameter_schema: %{},
          callback: fn _args -> {:ok, "sunny"} end
        )

      assert {:error, %ReqLLM.Error.Invalid.NotImplemented{}} =
               ReqLLM.generate_text(@model_id, "Hi",
                 tools: [dummy_tool],
                 provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
               )
    end

    test ":object operation rejects with NotImplemented (MCP sidecar follow-up)" do
      schema = [name: [type: :string, required: true]]

      assert {:error, %ReqLLM.Error.Invalid.NotImplemented{}} =
               ReqLLM.generate_object(@model_id, "give a name", schema,
                 provider_options: [claude_binary: ClaudeAgent.fake_cli_path()]
               )
    end
  end

  defp capability_cause(%ReqLLM.Error.Invalid.Capability{} = err), do: err
  defp capability_cause(%{cause: %ReqLLM.Error.Invalid.Capability{} = err}), do: err
  defp capability_cause(other), do: other
end
