defmodule ReqLLM.Test.ClaudeAgent do
  @moduledoc """
  Helpers for driving the `:claude_agent` provider against the fake `claude`
  binary shipped under `test/support/claude_agent/`.
  """

  @fake_cli Path.expand("../../../test/support/claude_agent/fake_cli.sh", __DIR__)
  @fixtures_dir Path.expand("../../../test/support/claude_agent/fixtures", __DIR__)

  @doc """
  Absolute path to the bundled fake `claude` binary.
  """
  @spec fake_cli_path() :: String.t()
  def fake_cli_path do
    @fake_cli
  end

  @doc """
  Absolute path to a fixture by stem (e.g. `"basic_text"`).
  """
  @spec fixture_path(String.t()) :: String.t()
  def fixture_path(name) do
    Path.join(@fixtures_dir, name <> ".jsonl")
  end

  @doc """
  Run `fun.()` with environment variables configured so the fake CLI knows
  which fixture to replay.
  """
  @spec with_fixture(String.t(), keyword(), (-> result)) :: result when result: any()
  def with_fixture(fixture_name, opts \\ [], fun) when is_function(fun, 0) do
    fixture_path = fixture_path(fixture_name)
    version = Keyword.get(opts, :version, "2.1.119")

    previous = %{
      "REQ_LLM_FAKE_CLAUDE_FIXTURE" => System.get_env("REQ_LLM_FAKE_CLAUDE_FIXTURE"),
      "REQ_LLM_FAKE_CLAUDE_VERSION" => System.get_env("REQ_LLM_FAKE_CLAUDE_VERSION")
    }

    System.put_env("REQ_LLM_FAKE_CLAUDE_FIXTURE", fixture_path)
    System.put_env("REQ_LLM_FAKE_CLAUDE_VERSION", version)
    ReqLLM.Providers.ClaudeAgent.CLI.invalidate_version_cache!()

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      ReqLLM.Providers.ClaudeAgent.CLI.invalidate_version_cache!()
    end
  end
end
