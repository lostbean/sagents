defmodule Sagents.SubAgentCallbackAccumulationTest do
  @moduledoc """
  Tests that callbacks don't accumulate across multiple HITL interrupt/resume
  cycles on a SubAgent.

  When SubAgent.resume/3 is called with callbacks, it should NOT re-add
  callbacks that were already added during execute/2. The chain persists
  across cycles, so callbacks from execute are already present. Re-adding
  them causes duplicate callback firings (duplicate LLM/TOOL spans in
  observability traces).
  """

  use Sagents.BaseCase, async: true
  use Mimic

  alias Sagents.SubAgent
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  setup :verify_on_exit!

  describe "callback accumulation across HITL cycles" do
    test "callbacks fire exactly once per assistant message even when passed to resume" do
      # Counter to track how many times on_message_processed fires for assistant messages
      callback_counter = :counters.new(1, [:atomics])

      # The callback we'll pass to both execute and resume (simulating SubAgentServer)
      # Only count assistant messages to isolate the duplication signal
      callbacks = %{
        on_message_processed: fn _chain, message ->
          if message.role == :assistant do
            :counters.add(callback_counter, 1, 1)
          end
        end
      }

      # Build a HITL tool that requires approval
      hitl_tool =
        LangChain.Function.new!(%{
          name: "write_file",
          description: "Write a file",
          parameters_schema: %{
            type: "object",
            required: ["path", "content"],
            properties: %{
              "path" => %{type: "string"},
              "content" => %{type: "string"}
            }
          },
          function: fn _args, _context -> {:ok, "File written"} end
        })

      # Build the SubAgent with interrupt_on for write_file
      model = mock_model()

      chain =
        LLMChain.new!(%{
          llm: model,
          custom_context: %{}
        })
        |> LLMChain.add_tools([hitl_tool])
        |> LLMChain.add_messages([
          Message.new_system!("You are a helpful assistant."),
          Message.new_user!("Write some files")
        ])

      subagent = %SubAgent{
        id: "test-subagent-1",
        parent_agent_id: "parent-1",
        chain: chain,
        interrupt_on: %{"write_file" => true},
        status: :idle,
        created_at: DateTime.utc_now()
      }

      # Stub ChatAnthropic.call to produce 3 cycles:
      # Cycle 1 (execute): LLM returns tool call → interrupt
      # Cycle 2 (resume): LLM returns tool call → interrupt again
      # Cycle 3 (resume): LLM returns final text → complete
      llm_call_count = :counters.new(1, [:atomics])

      tool_call_1 =
        ToolCall.new!(%{
          call_id: "tc-1",
          name: "write_file",
          arguments: %{"path" => "a.txt", "content" => "hello"}
        })

      tool_call_2 =
        ToolCall.new!(%{
          call_id: "tc-2",
          name: "write_file",
          arguments: %{"path" => "b.txt", "content" => "world"}
        })

      stub(ChatAnthropic, :call, fn _model, _messages, _tools ->
        count = :counters.get(llm_call_count, 1)
        :counters.add(llm_call_count, 1, 1)

        case count do
          0 ->
            # Cycle 1: return tool call that triggers interrupt
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call_1]})]}

          1 ->
            # Cycle 2: after first resume, return another tool call → interrupt again
            {:ok, [Message.new_assistant!(%{tool_calls: [tool_call_2]})]}

          _ ->
            # Cycle 3: after second resume, return final text → complete
            {:ok, [Message.new_assistant!("All files written successfully.")]}
        end
      end)

      # === Cycle 1: execute → interrupt ===
      :counters.put(callback_counter, 1, 0)

      assert {:interrupt, interrupted_1} = SubAgent.execute(subagent, callbacks: callbacks)
      assert interrupted_1.status == :interrupted

      # on_message_processed should have fired once (for the assistant message with tool call)
      cycle_1_count = :counters.get(callback_counter, 1)
      assert cycle_1_count == 1, "Cycle 1: expected 1 callback firing, got #{cycle_1_count}"

      # === Cycle 2: resume with same callbacks (simulating SubAgentServer) → interrupt again ===
      :counters.put(callback_counter, 1, 0)

      decisions_1 = [%{type: :approve}]

      assert {:interrupt, interrupted_2} =
               SubAgent.resume(interrupted_1, decisions_1, callbacks: callbacks)

      assert interrupted_2.status == :interrupted

      # on_message_processed should fire exactly once (for the new assistant message)
      # BUG: without the fix, this would be 2 (callbacks accumulated from execute + resume)
      cycle_2_count = :counters.get(callback_counter, 1)
      assert cycle_2_count == 1, "Cycle 2: expected 1 callback firing, got #{cycle_2_count}"

      # === Cycle 3: resume with same callbacks → complete ===
      :counters.put(callback_counter, 1, 0)

      decisions_2 = [%{type: :approve}]

      assert {:ok, completed} =
               SubAgent.resume(interrupted_2, decisions_2, callbacks: callbacks)

      assert completed.status == :completed

      # on_message_processed should fire exactly once (for the final assistant message)
      # BUG: without the fix, this would be 3 (callbacks accumulated again)
      cycle_3_count = :counters.get(callback_counter, 1)
      assert cycle_3_count == 1, "Cycle 3: expected 1 callback firing, got #{cycle_3_count}"
    end
  end
end
