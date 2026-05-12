defmodule ReqLLM.Providers.ClaudeAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.ClaudeAgent.{Control, Tools}

  defp weather_tool do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: "weather",
        description: "Get the weather for a city.",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn args -> {:ok, "sunny in #{args[:city] || args["city"]}"} end
      )

    tool
  end

  describe "prepare/1" do
    test "empty / missing :tools yields an empty registry" do
      assert {:ok, %Tools.State{registry: registry}} = Tools.prepare([])
      assert registry == %{}

      assert {:ok, %Tools.State{registry: registry}} = Tools.prepare(tools: nil)
      assert registry == %{}

      assert {:ok, %Tools.State{registry: registry}} = Tools.prepare(tools: [])
      assert registry == %{}
    end

    test "registers ReqLLM.Tool entries keyed by name" do
      tool = weather_tool()

      assert {:ok, %Tools.State{registry: %{"weather" => ^tool}}} =
               Tools.prepare(tools: [tool])
    end

    test "rejects non-tool entries with Invalid.Parameter" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Tools.prepare(tools: ["not-a-tool"])
    end
  end

  describe "advertise?/1" do
    test "true when registry has at least one tool" do
      {:ok, state} = Tools.prepare(tools: [weather_tool()])
      assert Tools.advertise?(state) == true
    end

    test "false on empty registry" do
      {:ok, state} = Tools.prepare([])
      assert Tools.advertise?(state) == false
    end
  end

  describe "dispatch_mcp/3 — tools/list" do
    test "returns the registered tools in JSON-RPC shape" do
      {:ok, state} = Tools.prepare(tools: [weather_tool()])

      request_id = "req-1"

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"}
      }

      {response_event, _state} = Tools.dispatch_mcp(request_id, payload, state)

      assert %{
               "type" => "control_response",
               "response" => %{
                 "subtype" => "success",
                 "request_id" => ^request_id,
                 "response" => %{
                   "jsonrpc" => "2.0",
                   "id" => 7,
                   "result" => %{"tools" => [tool_descriptor]}
                 }
               }
             } = response_event

      assert tool_descriptor["name"] == "weather"
      assert tool_descriptor["description"] =~ "weather"
      assert is_map(tool_descriptor["inputSchema"])
    end

    test "rejects unknown server_name" do
      {:ok, state} = Tools.prepare(tools: [weather_tool()])

      {response_event, _state} =
        Tools.dispatch_mcp(
          "req-1",
          %{
            "server_name" => "wrong-server",
            "message" => %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
          },
          state
        )

      assert %{"response" => %{"subtype" => "error"}} = response_event
    end
  end

  describe "dispatch_mcp/3 — tools/call" do
    test "happy path executes the callback and returns the result in MCP content shape" do
      {:ok, state} = Tools.prepare(tools: [weather_tool()])

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 11,
          "method" => "tools/call",
          "params" => %{"name" => "weather", "arguments" => %{"city" => "Paris"}}
        }
      }

      {response_event, new_state} = Tools.dispatch_mcp("req-x", payload, state)

      result = response_event["response"]["response"]["result"]
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text == "sunny in Paris"
      assert result["isError"] == false
      assert new_state.errors == []
    end

    test "unknown tool returns isError: true and records an error" do
      {:ok, state} = Tools.prepare(tools: [weather_tool()])

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 12,
          "method" => "tools/call",
          "params" => %{"name" => "nope", "arguments" => %{}}
        }
      }

      {response_event, new_state} = Tools.dispatch_mcp("req-y", payload, state)
      result = response_event["response"]["response"]["result"]
      assert result["isError"] == true
      assert new_state.errors |> hd() =~ "unknown tool"
    end

    test "callback that returns {:error, reason} surfaces isError: true" do
      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "boom",
          description: "fail",
          parameter_schema: [],
          callback: fn _ -> {:error, "boom!"} end
        )

      {:ok, state} = Tools.prepare(tools: [tool])

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 13,
          "method" => "tools/call",
          "params" => %{"name" => "boom", "arguments" => %{}}
        }
      }

      {response_event, new_state} = Tools.dispatch_mcp("req-z", payload, state)
      result = response_event["response"]["response"]["result"]
      assert result["isError"] == true
      assert [%{"type" => "text", "text" => "boom!"}] = result["content"]
      assert new_state.errors |> hd() =~ "boom: boom!"
    end

    test "callback that raises is caught and surfaces isError: true" do
      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "raiser",
          description: "raises",
          parameter_schema: [],
          callback: fn _ -> raise "kaboom" end
        )

      {:ok, state} = Tools.prepare(tools: [tool])

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 14,
          "method" => "tools/call",
          "params" => %{"name" => "raiser", "arguments" => %{}}
        }
      }

      {response_event, new_state} = Tools.dispatch_mcp("req-r", payload, state)
      result = response_event["response"]["response"]["result"]
      assert result["isError"] == true
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "kaboom"
      assert new_state.errors |> hd() =~ "raiser:"
    end

    test "non-string callback result is JSON-encoded" do
      {:ok, tool} =
        ReqLLM.Tool.new(
          name: "echo",
          description: "echo",
          parameter_schema: [],
          callback: fn args -> {:ok, %{echoed: args}} end
        )

      {:ok, state} = Tools.prepare(tools: [tool])

      payload = %{
        "server_name" => Tools.server_name(),
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 15,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"foo" => "bar"}}
        }
      }

      {response_event, _state} = Tools.dispatch_mcp("req-e", payload, state)

      [%{"type" => "text", "text" => text}] =
        response_event["response"]["response"]["result"]["content"]

      assert {:ok, %{"echoed" => %{"foo" => "bar"}}} = Jason.decode(text)
    end
  end

  describe "Control module envelopes" do
    test "initialize_request shape matches the SDK control protocol" do
      {id, event} = Control.initialize_request("init-1", ["req-llm-tools"])
      assert id == "init-1"

      assert event == %{
               "type" => "control_request",
               "request_id" => "init-1",
               "request" => %{
                 "subtype" => "initialize",
                 "sdkMcpServers" => ["req-llm-tools"]
               }
             }
    end

    test "mcp_success_response wraps a JSON-RPC response" do
      jsonrpc = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

      assert %{
               "type" => "control_response",
               "response" => %{
                 "subtype" => "success",
                 "request_id" => "abc",
                 "response" => ^jsonrpc
               }
             } = Control.mcp_success_response("abc", jsonrpc)
    end

    test "classify routes the three shapes correctly" do
      assert {:request, "mcp_message", "id-1", _} =
               Control.classify(%{
                 "type" => "control_request",
                 "request_id" => "id-1",
                 "request" => %{"subtype" => "mcp_message"}
               })

      assert {:response, "success", "id-2", _} =
               Control.classify(%{
                 "type" => "control_response",
                 "response" => %{"subtype" => "success", "request_id" => "id-2"}
               })

      assert :not_control =
               Control.classify(%{"type" => "system", "subtype" => "init"})
    end
  end
end
