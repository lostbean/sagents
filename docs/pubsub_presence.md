# PubSub & Presence

This document covers real-time event streaming and viewer tracking in Sagents.

## Overview

Sagents uses Phoenix.PubSub for real-time event broadcasting, enabling:
- Multiple LiveView clients watching the same conversation
- Real-time streaming of LLM responses
- TODO list and state synchronization
- Debug event streams for development tools

## PubSub Configuration

### Setup

1. Ensure Phoenix.PubSub is started in your application:

```elixir
# application.ex
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  # ... other children
]
```

2. Pass PubSub to AgentServer:

```elixir
AgentServer.start_link(
  agent: agent,
  pubsub: {Phoenix.PubSub, MyApp.PubSub}
)
```

### Topics

Each agent broadcasts on two topics:

| Topic | Purpose |
|-------|---------|
| `"agent_server:#{agent_id}"` | Main events (status, messages, todos) |
| `"agent_server:debug:#{agent_id}"` | Debug events (state snapshots, middleware actions) |

## Subscribing to Events

### Main Events

```elixir
# In your LiveView or GenServer
def mount(%{"id" => id}, _session, socket) do
  if connected?(socket) do
    AgentServer.subscribe("conversation-#{id}")
  end
  {:ok, socket}
end

def handle_info({:agent, event}, socket) do
  # Handle the event
  {:noreply, handle_agent_event(event, socket)}
end
```

### Debug Events

```elixir
# For development/debugging tools
AgentServer.subscribe_debug("conversation-123")

def handle_info({:agent, {:debug, debug_event}}, socket) do
  case debug_event do
    {:agent_state_update, state} ->
      # Full state snapshot
      {:noreply, assign(socket, debug_state: state)}

    {:middleware_action, module, data} ->
      # Middleware-specific event
      {:noreply, log_middleware_action(socket, module, data)}
  end
end
```

## Event Reference

### Status Events

```elixir
{:agent, {:status_changed, status, data}}
```

| Status | Data | Description |
|--------|------|-------------|
| `:idle` | `nil` | Agent ready, not executing |
| `:running` | `nil` | Execution in progress |
| `:interrupted` | `%InterruptData{}` | Waiting for HITL approval |
| `:cancelled` | `nil` | User cancelled execution |
| `:error` | `reason` | Execution failed |

Example handler:

```elixir
def handle_agent_event({:status_changed, status, data}, socket) do
  case {status, data} do
    {:running, nil} ->
      socket
      |> assign(status: :running)
      |> assign(streaming_content: "")

    {:idle, nil} ->
      assign(socket, status: :idle)

    {:interrupted, interrupt_data} ->
      socket
      |> assign(status: :interrupted)
      |> assign(interrupt: interrupt_data)
      |> push_event("show_approval_modal", %{})

    {:error, reason} ->
      socket
      |> assign(status: :error)
      |> put_flash(:error, "Agent error: #{inspect(reason)}")

    {:cancelled, nil} ->
      assign(socket, status: :cancelled)
  end
end
```

### LLM Message Events

```elixir
# Streaming tokens (during generation)
{:agent, {:llm_deltas, [%MessageDelta{}, ...]}}

# Complete message (after generation)
{:agent, {:llm_message, %Message{}}}

# Token usage info
{:agent, {:llm_token_usage, %TokenUsage{}}}
```

Example streaming handler:

```elixir
def handle_agent_event({:llm_deltas, deltas}, socket) do
  # Accumulate streaming content
  new_content =
    Enum.reduce(deltas, socket.assigns.streaming_content, fn delta, acc ->
      acc <> (delta.content || "")
    end)

  socket
  |> assign(streaming_content: new_content)
  |> push_event("scroll_to_bottom", %{})
end

def handle_agent_event({:llm_message, message}, socket) do
  # Complete message received - add to history
  socket
  |> update(:messages, &(&1 ++ [message]))
  |> assign(streaming_content: "")
end

def handle_agent_event({:llm_token_usage, usage}, socket) do
  # Update token counts for display
  assign(socket, token_usage: usage)
end
```

### TODO Events

```elixir
{:agent, {:todos_updated, [%Todo{}, ...]}}
```

The TODO list is a complete snapshot (not a diff):

```elixir
def handle_agent_event({:todos_updated, todos}, socket) do
  # Replace entire TODO list
  assign(socket, todos: todos)
end
```

### Tool Events

```elixir
# Tool call executed
{:agent, {:tool_call_executed, %{
  tool_call: %ToolCall{},
  result: %ToolResult{}
}}}

# Tool call pending HITL (before interrupt)
{:agent, {:tool_call_pending, %ToolCall{}}}
```

### Shutdown Event

```elixir
{:agent, {:agent_shutdown, %{reason: reason, metadata: map}}}
```

Reasons:
- `:inactivity` - Timeout expired
- `:no_viewers` - No presence after completion
- `:manual` - Explicitly stopped
- `:crash` - Process crashed (rare)

```elixir
def handle_agent_event({:agent_shutdown, %{reason: reason}}, socket) do
  case reason do
    :inactivity ->
      # Agent timed out - can restart on user action
      socket
      |> assign(agent_status: :inactive)
      |> put_flash(:info, "Conversation paused due to inactivity")

    :no_viewers ->
      # Normal cleanup after completion
      assign(socket, agent_status: :inactive)

    _ ->
      assign(socket, agent_status: :stopped)
  end
end
```

### Display Message Events

```elixir
# Message was persisted to database
{:agent, {:display_message_saved, display_message}}
```

Useful for syncing UI with database state.

## Debug Events

Debug events provide detailed insight into agent internals.

> **Note:** While you can subscribe to debug events directly, the `sagents_live_debugger` package already uses these events to provide a powerful real-time debugging dashboard. It visualizes agent state, middleware actions, and sub-agent hierarchies out of the box. See the [Live Debugger documentation](https://github.com/sagents-ai/sagents_live_debugger/README.md) for setup instructions.

### State Updates

```elixir
{:agent, {:debug, {:agent_state_update, %State{}}}}
```

Full state snapshot after each execution step.

### Middleware Actions

```elixir
{:agent, {:debug, {:middleware_action, module, data}}}
```

Each middleware can emit custom debug events:

| Middleware | Event | Data |
|------------|-------|------|
| `Summarization` | `:summarization_started` | Token count info |
| `Summarization` | `:summarization_completed` | Message count reduction |
| `PatchToolCalls` | `:dangling_tool_calls_patched` | Patch count |
| `ConversationTitle` | `:title_generated` | Generated title |
| `HumanInTheLoop` | `:interrupt_triggered` | Tool calls requiring approval |

Example debug handler:

```elixir
def handle_info({:agent, {:debug, event}}, socket) do
  case event do
    {:agent_state_update, state} ->
      {:noreply, update(socket, :debug_log, &[{:state, state} | &1])}

    {:middleware_action, Sagents.Middleware.Summarization, {:summarization_completed, info}} ->
      {:noreply, update(socket, :debug_log, &[{:summarization, info} | &1])}

    {:middleware_action, module, data} ->
      {:noreply, update(socket, :debug_log, &[{module, data} | &1])}
  end
end
```

## Publishing Custom Events

### From Middleware

Middleware can publish events using the AgentServer API:

```elixir
defmodule MyMiddleware do
  @behaviour Sagents.Middleware

  def after_model(state, _config) do
    # Publish custom event
    AgentServer.publish_event_from(
      state.agent_id,
      {:my_custom_event, %{data: "something"}}
    )

    # Publish debug event (separate topic)
    AgentServer.publish_debug_event_from(
      state.agent_id,
      {:middleware_action, __MODULE__, {:custom_action, "details"}}
    )

    {:ok, state}
  end
end
```

### Event Structure

Events are always wrapped in `{:agent, event}`:

```elixir
# What you publish
AgentServer.publish_event_from(agent_id, {:my_event, data})

# What subscribers receive
{:agent, {:my_event, data}}
```

## Phoenix.Presence Integration

### Overview

Presence tracking enables:
- Knowing how many clients are viewing a conversation
- Automatic shutdown when all viewers leave
- Displaying who else is viewing

### Setup

1. Create a Presence module:

```elixir
defmodule MyApp.Presence do
  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end
```

2. Start it in your application:

```elixir
children = [
  MyApp.Presence,
  # ...
]
```

3. Configure AgentServer:

```elixir
AgentServer.start_link(
  agent: agent,
  pubsub: {Phoenix.PubSub, MyApp.PubSub},
  presence_tracking: [
    enabled: true,
    presence_module: MyApp.Presence,
    topic: "conversation:#{conversation_id}",
    grace_period: 5_000  # 5 seconds before shutdown
  ]
)
```

### Tracking Viewers

In your LiveView:

```elixir
def mount(%{"id" => conversation_id}, _session, socket) do
  topic = "conversation:#{conversation_id}"

  if connected?(socket) do
    # Subscribe to agent events
    AgentServer.subscribe("conversation-#{conversation_id}")

    # Track this viewer
    {:ok, _} = MyApp.Presence.track(
      self(),
      topic,
      socket.assigns.current_user.id,
      %{
        user_name: socket.assigns.current_user.name,
        joined_at: DateTime.utc_now()
      }
    )

    # Subscribe to presence changes
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
  end

  {:ok, assign(socket, topic: topic)}
end

# Handle presence changes
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
  presence = MyApp.Presence.list(socket.assigns.topic)
  {:noreply, assign(socket, viewers: presence)}
end
```

### Displaying Viewers

```elixir
def render(assigns) do
  ~H"""
  <div class="viewers">
    <%= for {user_id, %{metas: metas}} <- @viewers do %>
      <span class="viewer" title={hd(metas).user_name}>
        <%= String.first(hd(metas).user_name) %>
      </span>
    <% end %>
  </div>
  """
end
```

### How Presence Affects Shutdown

1. Agent completes execution (status: `:idle`)
2. AgentServer checks presence count
3. If no viewers: start grace period timer
4. During grace period: if viewer joins, cancel shutdown
5. After grace period: save state and terminate

```
Execution completes → Check presence → No viewers → Grace period → Shutdown
                           ↓
                      Has viewers → Stay running
```

## Multiple Subscribers

Multiple LiveView processes can subscribe to the same agent:

```elixir
# Tab 1
AgentServer.subscribe("conversation-123")

# Tab 2 (same or different user)
AgentServer.subscribe("conversation-123")

# Both receive all events
```

This enables:
- Multiple browser tabs with same conversation
- Shared conversations between users
- Admin dashboards monitoring user conversations

## Event Ordering

Events are delivered in order per agent, but:
- No ordering guarantee across different agents
- Deltas may batch multiple tokens
- State updates are eventual (not transactional)

For consistency:
- Use `{:llm_message, msg}` for final message content (not accumulated deltas)
- Use `{:todos_updated, todos}` snapshots (not diffs)
- Handle `{:agent_shutdown, _}` to detect agent going away

## Best Practices

### 1. Always Check Connection

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Only subscribe when actually connected
    AgentServer.subscribe(agent_id)
  end
  {:ok, socket}
end
```

### 2. Handle Agent Not Running

```elixir
def mount(%{"id" => id}, _session, socket) do
  case Coordinator.start_conversation_session(id) do
    {:ok, session} ->
      AgentServer.subscribe(session.agent_id)
      {:ok, assign(socket, agent_id: session.agent_id)}

    {:error, :not_found} ->
      {:ok, redirect(socket, to: ~p"/conversations")}
  end
end
```

### 3. Explicit Unsubscription

Subscriptions are automatically cleaned up when the LiveView process terminates. However, you can explicitly unsubscribe when your application needs to disconnect for other reasons:

```elixir
@impl true
def handle_event("close_conversation", _params, socket) do
  AgentServer.unsubscribe(socket.assigns.agent_id)
  # ... other logic ...
  {:noreply, socket}
end
```
