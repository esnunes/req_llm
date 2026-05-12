#!/usr/bin/env elixir

# Fake `claude` binary used by the :claude_agent provider tests.
#
# Behaviour:
#   1. If invoked with `--version`, print the version from the env var
#      REQ_LLM_FAKE_CLAUDE_VERSION (default "2.1.119") and exit 0.
#   2. Otherwise, read the entire stdin, then emit the stream-json events
#      stored in the JSONL fixture pointed at by the env var
#      REQ_LLM_FAKE_CLAUDE_FIXTURE. Lines after the first are emitted in
#      order; the first line is treated as a "header" with optional
#      `exit_code` and `stderr` fields.

defmodule FakeClaudeCLI do
  def run(argv) do
    if "--version" in argv do
      version = System.get_env("REQ_LLM_FAKE_CLAUDE_VERSION") || "2.1.119"
      IO.puts(version)
      System.halt(0)
    end

    case System.get_env("REQ_LLM_FAKE_CLAUDE_FIXTURE") do
      nil ->
        IO.puts(:stderr, "FAKE-CLI: REQ_LLM_FAKE_CLAUDE_FIXTURE not set")
        System.halt(2)

      path ->
        replay(path)
    end
  end

  defp replay(path) do
    lines = path |> File.read!() |> String.split("\n", trim: true)
    {header_line, events} = List.pop_at(lines, 0)

    header =
      case header_line do
        nil ->
          %{}

        line ->
          case Jason.decode(line) do
            {:ok, %{} = h} -> h
            _ -> %{}
          end
      end

    stderr = Map.get(header, "stderr")
    if is_binary(stderr) and stderr != "", do: IO.write(:stderr, stderr)

    # Drain stdin so the parent doesn't see EPIPE on its writes.
    _ = IO.read(:stdio, :eof)

    Enum.each(events, fn line -> IO.puts(line) end)

    exit_code = Map.get(header, "exit_code", 0)
    System.halt(exit_code)
  end
end

FakeClaudeCLI.run(System.argv())
