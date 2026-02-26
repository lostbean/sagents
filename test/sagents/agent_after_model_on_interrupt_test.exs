defmodule Sagents.Agent.AfterModelOnInterruptTest do
  @moduledoc """
  Tests that after_model middleware hooks fire even when execute_model
  returns {:interrupt, ...}.

  Currently, Agent.execute/3 skips after_model hooks on interrupt
  (see lib/sagents/agent.ex, the {:interrupt, ...} clause in execute/3).
  This test demonstrates the bug: after_model should still run so that
  middleware can perform cleanup, logging, state enrichment, etc.
  """

  use Sagents.BaseCase, async: false
  use Mimic

  alias Sagents.Agent
  alias Sagents.Middleware
  alias Sagents.State
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Function
  alias Sagents.Middleware.HumanInTheLoop

  # ---------------------------------------------------------------------------
  # Test middleware: records before_model / after_model invocations by sending
  # messages to the test process.
  # ---------------------------------------------------------------------------
  defmodule SpanTracker do
    @behaviour Middleware

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def before_model(state, _config) do
      send(Process.get(:test_pid), :before_model_called)
      {:ok, state}
    end

    @impl true
    def after_model(state, _config) do
      send(Process.get(:test_pid), :after_model_called)
      {:ok, state}
    end
  end

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_write_file_tool do
    Function.new!(%{
      name: "write_file",
      description: "Write content to a file",
      parameters_schema: %{
        type: "object",
        properties: %{
          "path" => %{type: "string", description: "File path"},
          "content" => %{type: "string", description: "File content"}
        },
        required: ["path", "content"]
      },
      function: fn _args, _context -> {:ok, "done"} end
    })
  end

  defp stub_llm_with_tool_call(tool_name, tool_args) do
    tool_call =
      ToolCall.new!(%{
        call_id: "call-#{:rand.uniform(10_000)}",
        name: tool_name,
        arguments: tool_args
      })

    ChatAnthropic
    |> stub(:call, fn _model, _messages, _tools ->
      {:ok, [Message.new_assistant!(%{tool_calls: [tool_call]})]}
    end)

    tool_call
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "after_model hooks on interrupt" do
    test "after_model fires even when execute_model returns {:interrupt, ...}" do
      stub_llm_with_tool_call("write_file", %{
        "path" => "test.txt",
        "content" => "hello"
      })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            base_system_prompt: "Test agent",
            tools: [create_write_file_tool()],
            middleware: [
              SpanTracker,
              {HumanInTheLoop, [interrupt_on: %{"write_file" => true}]}
            ]
          },
          interrupt_on: %{"write_file" => true},
          replace_default_middleware: true
        )

      initial_state =
        State.new!(%{
          messages: [Message.new_user!("Write a file")]
        })

      # Execute should return an interrupt because the tool call matches interrupt_on
      assert {:interrupt, _state, _interrupt_data} = Agent.execute(agent, initial_state)

      # before_model must have been called
      assert_received :before_model_called

      # BUG: after_model is currently skipped when execute_model returns {:interrupt, ...}.
      # This assertion will fail until the bug is fixed.
      assert_received :after_model_called
    end

    test "after_model hooks run in reverse order on interrupt, same as on normal completion" do
      stub_llm_with_tool_call("write_file", %{
        "path" => "test.txt",
        "content" => "hello"
      })

      test_pid = self()

      # Define a second tracker to verify ordering
      defmodule SecondTracker do
        @behaviour Middleware

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def before_model(state, _config) do
          send(Process.get(:test_pid), {:before_model, :second})
          {:ok, state}
        end

        @impl true
        def after_model(state, _config) do
          send(Process.get(:test_pid), {:after_model, :second})
          {:ok, state}
        end
      end

      # Override SpanTracker to send tagged messages for ordering verification
      defmodule FirstTracker do
        @behaviour Middleware

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def before_model(state, _config) do
          send(Process.get(:test_pid), {:before_model, :first})
          {:ok, state}
        end

        @impl true
        def after_model(state, _config) do
          send(Process.get(:test_pid), {:after_model, :first})
          {:ok, state}
        end
      end

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            base_system_prompt: "Test agent",
            tools: [create_write_file_tool()],
            middleware: [
              FirstTracker,
              SecondTracker,
              {HumanInTheLoop, [interrupt_on: %{"write_file" => true}]}
            ]
          },
          interrupt_on: %{"write_file" => true},
          replace_default_middleware: true
        )

      initial_state =
        State.new!(%{
          messages: [Message.new_user!("Write a file")]
        })

      assert {:interrupt, _state, _interrupt_data} = Agent.execute(agent, initial_state)

      # before_model hooks fire in order: first, then second
      assert_received {:before_model, :first}
      assert_received {:before_model, :second}

      # after_model hooks should fire in reverse order: second, then first
      # (same convention as normal completion)
      assert_received {:after_model, :second}
      assert_received {:after_model, :first}
    end

    test "interrupt data is preserved when after_model hooks run" do
      stub_llm_with_tool_call("write_file", %{
        "path" => "important.txt",
        "content" => "data"
      })

      {:ok, agent} =
        Agent.new(
          %{
            model: mock_model(),
            base_system_prompt: "Test agent",
            tools: [create_write_file_tool()],
            middleware: [
              SpanTracker,
              {HumanInTheLoop, [interrupt_on: %{"write_file" => true}]}
            ]
          },
          interrupt_on: %{"write_file" => true},
          replace_default_middleware: true
        )

      initial_state =
        State.new!(%{
          messages: [Message.new_user!("Write a file")]
        })

      result = Agent.execute(agent, initial_state)

      assert {:interrupt, _state, interrupt_data} = result

      # The interrupt data should still contain the action requests
      assert %{action_requests: [action]} = interrupt_data
      assert action.tool_name == "write_file"

      # And after_model should have been called
      assert_received :after_model_called
    end
  end
end
