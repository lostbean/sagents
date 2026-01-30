defmodule Sagents.AgentServerToolCallbacksTest do
  @moduledoc """
  Tests for AgentServer tool execution callback functionality.

  This verifies that the new tool execution events are properly broadcast:
  1. tool_execution_started with display_text
  2. tool_execution_completed
  3. tool_execution_failed
  4. Friendly name fallback for tools without display_text
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.{Agent, AgentServer, AgentSupervisor}
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{Message, Function}
  alias LangChain.Message.{ToolCall, ToolResult}

  setup :set_mimic_global

  # Helper to start agent with tools
  defp start_agent_with_tools(agent_id, tools) do
    # Subscribe to PubSub first
    Phoenix.PubSub.subscribe(:test_pubsub, "agent_server:#{agent_id}")

    model =
      ChatAnthropic.new!(%{
        model: "claude-3-5-sonnet-20241022",
        api_key: "test_key"
      })

    {:ok, agent} =
      Agent.new(%{
        agent_id: agent_id,
        model: model,
        base_system_prompt: "Test agent",
        replace_default_middleware: true,
        middleware: [],
        tools: tools
      })

    {:ok, _pid} =
      AgentSupervisor.start_link(
        name: AgentSupervisor.get_name(agent_id),
        agent: agent,
        pubsub: {Phoenix.PubSub, :test_pubsub}
      )

    agent_id
  end

  defp stop_agent(agent_id) do
    AgentServer.stop(agent_id)
  end

  describe "tool_execution_started event" do
    test "broadcasts with display_text" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "test_tool",
          description: "A test tool",
          display_text: "Testing something",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Success"} end
        })

      # Mock LLM to return tool call
      stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Using tool",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_123",
                 name: "test_tool",
                 arguments: %{"arg" => "value"}
               })
             ]
           })
         ]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Verify tool_execution_started event
      assert_receive {:agent, {:tool_execution_started, tool_info}}

      assert tool_info.call_id == "call_123"
      assert tool_info.name == "test_tool"
      assert tool_info.display_text == "Testing something"
      assert tool_info.arguments == %{"arg" => "value"}

      stop_agent(agent_id)
    end

    test "uses friendly fallback when display_text is nil" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "web_search",
          description: "Search",
          # No display_text
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Results"} end
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Searching",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_456",
                 name: "web_search",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Search"))

      assert_receive {:agent, {:tool_execution_started, tool_info}}

      assert tool_info.name == "web_search"
      # Fallback: "web_search" -> "Web search"
      assert tool_info.display_text == "Web search"

      stop_agent(agent_id)
    end
  end

  describe "tool_execution_completed event" do
    test "broadcasts when tool succeeds" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "success_tool",
          description: "Succeeds",
          display_text: "Succeeding",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:ok, "Success result"} end
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "OK",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_789",
                 name: "success_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get both started and completed
      assert_receive {:agent, {:tool_execution_started, _}}
      assert_receive {:agent, {:tool_execution_completed, call_id, tool_result}}

      assert call_id == "call_789"
      assert %ToolResult{} = tool_result
      # Tool result content will be ContentPart list
      assert tool_result.is_error == false

      stop_agent(agent_id)
    end
  end

  describe "tool_execution_failed event" do
    test "broadcasts when tool fails" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      tool =
        Function.new!(%{
          name: "failing_tool",
          description: "Fails",
          display_text: "Trying",
          parameters_schema: %{type: "object", properties: %{}},
          function: fn _args, _ctx -> {:error, "Tool error"} end
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Trying",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_fail",
                 name: "failing_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      start_agent_with_tools(agent_id, [tool])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get started but then failed
      assert_receive {:agent, {:tool_execution_started, _}}
      assert_receive {:agent, {:tool_execution_failed, call_id, error_msg}}

      assert call_id == "call_fail"
      assert is_binary(error_msg)

      stop_agent(agent_id)
    end

    test "broadcasts for non-existent tool" do
      agent_id = "test-#{:erlang.unique_integer([:positive])}"

      stub(ChatAnthropic, :call, fn _model, _messages, _callbacks ->
        {:ok,
         [
           Message.new_assistant!(%{
             content: "Using",
             tool_calls: [
               ToolCall.new!(%{
                 call_id: "call_invalid",
                 name: "nonexistent_tool",
                 arguments: %{}
               })
             ]
           })
         ]}
      end)

      # No tools!
      start_agent_with_tools(agent_id, [])

      AgentServer.add_message(agent_id, Message.new_user!("Test"))

      # Should get failed event for invalid tool
      assert_receive {:agent, {:tool_execution_failed, call_id, error_msg}}

      assert call_id == "call_invalid"
      assert error_msg =~ "tool not found"

      stop_agent(agent_id)
    end
  end
end
