defmodule ReqLLM.Providers.ClaudeAgent.Tools do
  @moduledoc """
  User-defined tool advertisement and dispatch for the Claude Code CLI.

  V1 scope: when no user-defined tools are passed, this module is a no-op.
  When user-defined tools *are* passed, the MCP stdio sidecar that would
  expose them to the CLI is not yet implemented, so the call raises a
  typed `ReqLLM.Error.Invalid.NotImplemented` with a clear pointer.

  This keeps the rest of the provider compilable and the supported paths
  (text generation, streaming, built-in tools) functional while the
  sidecar work is tracked as a follow-up.
  """

  @spec advertise(keyword()) :: :ok | {:error, Exception.t()}
  def advertise(opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) and tools != [] ->
        {:error,
         ReqLLM.Error.Invalid.NotImplemented.exception(
           feature:
             "user-defined ReqLLM.Tool registration via the :claude_agent provider. " <>
               "The MCP stdio sidecar that advertises tools to the CLI is a follow-up. " <>
               "Use :allowed_tools / :disallowed_tools for built-in Claude Code tools in the meantime."
         )}

      _ ->
        :ok
    end
  end

  @doc false
  def teardown(_state), do: :ok
end
