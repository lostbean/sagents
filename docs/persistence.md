# State Persistence

This document covers saving and restoring agent conversations.

## Overview

Sagents separates **configuration** from **state**:

| Component | Stored In | Contains |
|-----------|-----------|----------|
| Configuration | Code | Model, middleware, tools, prompts |
| State | Database | Messages, todos, metadata |

This separation means:
- You can update middleware without migrating data
- Agent capabilities are version-controlled with code
- Secrets (API keys) stay out of the database

## Data Model

### What Gets Persisted

```elixir
# State structure
%State{
  agent_id: "conversation-123",     # Links to conversation
  messages: [...],                  # Full conversation history
  todos: [...],                     # Current TODO list
  metadata: %{                      # Middleware-specific data
    "conversation_title" => "...",
    "preferences" => %{...}
  },
  interrupt: nil                    # Pending HITL (if any)
}
```

### What Stays in Code

```elixir
# Agent configuration
%Agent{
  model: %ChatAnthropic{...},      # LLM configuration
  middleware: [...],                # Middleware stack
  tools: [...],                     # Additional tools
  base_system_prompt: "...",        # System prompt
  callbacks: %{...}                 # Event callbacks
}
```

## Code Generator

### Basic Usage

```bash
mix sagents.gen.persistence MyApp.Conversations
```

This generates:
- `lib/my_app/conversations.ex` - Context module
- `lib/my_app/conversations/conversation.ex` - Conversation schema
- `lib/my_app/conversations/agent_state.ex` - State schema
- `lib/my_app/conversations/display_message.ex` - UI message schema
- `priv/repo/migrations/..._create_conversations.exs` - Migration

### With Options

```bash
mix sagents.gen.persistence MyApp.Conversations \
  --scope MyApp.Accounts.Scope \
  --owner-type user \
  --owner-field user_id \
  --owner-module MyApp.Accounts.User \
  --table-prefix sagents_
```

Options:
- `--scope` - Application scope module (required)
- `--owner-type` - Owner type (user, account, team, org, none)
- `--owner-field` - Foreign key field name
- `--owner-module` - Owner schema module
- `--table-prefix` - Database table prefix

## Generated Schemas

### Conversation

```elixir
defmodule MyApp.Conversations.Conversation do
  use Ecto.Schema

  schema "sagents_conversations" do
    field :title, :string
    field :scope, :map  # {:user, 123} stored as %{"type" => "user", "id" => 123}

    belongs_to :user, MyApp.Accounts.User

    has_one :agent_state, MyApp.Conversations.AgentState
    has_many :display_messages, MyApp.Conversations.DisplayMessage

    timestamps()
  end
end
```

### AgentState

```elixir
defmodule MyApp.Conversations.AgentState do
  use Ecto.Schema

  schema "sagents_agent_states" do
    field :data, :map  # Serialized State struct

    belongs_to :conversation, MyApp.Conversations.Conversation

    timestamps()
  end
end
```

### DisplayMessage

```elixir
defmodule MyApp.Conversations.DisplayMessage do
  use Ecto.Schema

  schema "sagents_display_messages" do
    field :role, Ecto.Enum, values: [:user, :assistant, :tool, :system]
    field :content, :string
    field :metadata, :map  # Tool calls, token usage, etc.
    field :sequence, :integer  # Ordering

    belongs_to :conversation, MyApp.Conversations.Conversation

    timestamps()
  end
end
```

## Context Module

The generated context provides CRUD operations:

```elixir
defmodule MyApp.Conversations do
  # Conversation CRUD
  def create_conversation(scope, attrs)
  def get_conversation(scope, id)
  def update_conversation(conversation, attrs)
  def delete_conversation(scope, id)
  def list_conversations(scope, opts \\ [])

  # Agent state
  def save_agent_state(conversation_id, state)
  def load_agent_state(conversation_id)

  # Display messages
  def append_display_message(conversation_id, role, content, metadata \\ %{})
  def load_display_messages(conversation_id)
  def clear_display_messages(conversation_id)
end
```

## Usage Patterns

### Creating a Conversation

```elixir
# Get scope from current user
scope = {:user, current_user.id}

# Create conversation
{:ok, conversation} = MyApp.Conversations.create_conversation(scope, %{
  title: "New Chat"
})

# Conversation is now ready for an agent
```

### Starting an Agent with Persistence

```elixir
defmodule MyApp.Agents.Coordinator do
  def start_conversation_session(conversation_id) do
    agent_id = "conversation-#{conversation_id}"

    case AgentServer.whereis(agent_id) do
      nil -> start_new_agent(agent_id, conversation_id)
      pid -> {:ok, %{agent_id: agent_id, pid: pid}}
    end
  end

  defp start_new_agent(agent_id, conversation_id) do
    # Load or create state
    initial_state = case Conversations.load_agent_state(conversation_id) do
      {:ok, state} -> state
      {:error, :not_found} -> State.new!()
    end

    # Create agent from code
    {:ok, agent} = AgentFactory.create_agent(agent_id: agent_id)

    # Start with auto-save
    {:ok, pid} = AgentServer.start_link(
      agent: agent,
      initial_state: initial_state,
      pubsub: {Phoenix.PubSub, MyApp.PubSub},
      auto_save: [
        callback: fn _id, state ->
          Conversations.save_agent_state(conversation_id, state)
        end,
        interval: 30_000,
        on_idle: true
      ],
      display_message_callback: fn msg ->
        Conversations.append_display_message(conversation_id, msg)
      end
    )

    {:ok, %{agent_id: agent_id, pid: pid}}
  end
end
```

### Auto-Save Configuration

```elixir
AgentServer.start_link(
  agent: agent,
  auto_save: [
    # Function called to save state
    callback: fn agent_id, state ->
      conversation_id = extract_conversation_id(agent_id)
      Conversations.save_agent_state(conversation_id, state)
    end,

    # Save interval (only if changed)
    interval: 30_000,  # 30 seconds

    # Save when execution completes
    on_idle: true,

    # Save before shutdown
    on_shutdown: true  # default: true
  ]
)
```

### Manual Save

```elixir
# Get current state
state = AgentServer.export_state(agent_id)

# Save to database
Conversations.save_agent_state(conversation_id, state)
```

### Loading Conversations

```elixir
# List user's conversations
conversations = Conversations.list_conversations(scope, [
  order_by: [desc: :updated_at],
  limit: 20
])

# Get specific conversation with messages
conversation = Conversations.get_conversation(scope, id)
display_messages = Conversations.load_display_messages(id)
```

## Display Messages

Display messages are a UI-friendly representation of the conversation:

### Why Separate from State?

1. **Performance**: Don't deserialize full state just to show message list
2. **Flexibility**: Format content differently for UI vs LLM
3. **History**: Keep display messages even if the Agent's internal state is summarized

### Saving Display Messages

```elixir
# Configure callback when starting agent
AgentServer.start_link(
  agent: agent,
  display_message_callback: fn role, content, metadata ->
    Conversations.append_display_message(
      conversation_id,
      role,
      content,
      metadata
    )
  end
)

# Or save manually based on events
def handle_info({:agent, {:llm_message, message}}, socket) do
  Conversations.append_display_message(
    socket.assigns.conversation_id,
    :assistant,
    message.content,
    %{token_usage: extract_usage(message)}
  )
  {:noreply, socket}
end
```

### Loading for UI

```elixir
def mount(%{"id" => id}, _session, socket) do
  conversation = Conversations.get_conversation(scope, id)
  messages = Conversations.load_display_messages(id)

  {:ok, assign(socket,
    conversation: conversation,
    messages: messages
  )}
end
```

## Serialization

### State Serialization

```elixir
# State.to_serialized/1
%{
  "messages" => [
    %{
      "role" => "user",
      "content" => "Hello",
      "metadata" => %{}
    },
    %{
      "role" => "assistant",
      "content" => "Hi there!",
      "tool_calls" => [],
      "metadata" => %{}
    }
  ],
  "todos" => [
    %{
      "id" => "todo-1",
      "content" => "Task description",
      "status" => "completed"
    }
  ],
  "metadata" => %{
    "conversation_title" => "Greeting",
    "custom_data" => %{...}
  }
}
```

### State Deserialization

```elixir
# State.from_serialized/2
{:ok, state} = State.from_serialized(agent_id, serialized_data)
```

The `agent_id` is required because it's not stored in the serialized data (it's the conversation's identity).

### Custom Serialization

Middleware can define custom serialization:

```elixir
defmodule MyMiddleware do
  @behaviour Sagents.Middleware

  @impl true
  def state_schema do
    [
      my_data: %{
        serialize: fn data -> Base.encode64(:erlang.term_to_binary(data)) end,
        deserialize: fn str -> :erlang.binary_to_term(Base.decode64!(str)) end
      }
    ]
  end
end
```

## Migration Patterns

### Adding New Middleware

When adding middleware to existing agents, the middleware itself should handle missing state gracefully rather than migrating stored agent state. This keeps migration logic colocated with the middleware and avoids touching persisted data:

```elixir
defmodule MyNewMiddleware do
  @behaviour Sagents.Middleware

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def before_model(state, _config) do
    # Initialize state if this middleware hasn't been used before
    state = case State.get_metadata(state, :my_feature) do
      nil -> State.put_metadata(state, :my_feature, default_value())
      _ -> state
    end

    {:ok, state}
  end

  defp default_value, do: %{initialized: true, data: []}
end
```

This approach is preferred because:
- Migration logic lives with the middleware, not in persistence layer
- No database migrations needed when adding middleware
- Each middleware is responsible for its own defaults
- Existing conversations seamlessly gain new capabilities

### Changing Middleware Configuration

Since middleware config is in code, just update the code:

```elixir
# Before
{FileSystem, [enabled_tools: ["ls", "read_file"]]}

# After - existing states work fine
{FileSystem, [enabled_tools: ["ls", "read_file", "write_file"]]}
```

### Removing Middleware

Orphaned metadata is harmless and can be left in place:

```elixir
# Before
middleware: [TodoList, OldMiddleware, FileSystem]

# After - OldMiddleware's metadata stays in state but is ignored
middleware: [TodoList, FileSystem]
```

The unused metadata has no effect on agent behavior and will naturally disappear as conversations expire or are deleted.

## Scope Pattern

Scopes isolate data between users/organizations:

```elixir
defmodule MyApp.Accounts.Scope do
  defstruct [:type, :id]

  def for_user(user) do
    %__MODULE__{type: :user, id: user.id}
  end

  def for_org(org) do
    %__MODULE__{type: :organization, id: org.id}
  end
end
```

Usage in context:

```elixir
def list_conversations(%Scope{type: :user, id: user_id}, opts) do
  Conversation
  |> where([c], c.user_id == ^user_id)
  |> order_by([c], desc: c.updated_at)
  |> Repo.all()
end

def list_conversations(%Scope{type: :organization, id: org_id}, opts) do
  Conversation
  |> join(:inner, [c], u in User, on: c.user_id == u.id)
  |> where([c, u], u.organization_id == ^org_id)
  |> Repo.all()
end
```

## Best Practices

### 1. Always Use Scopes

```elixir
# Good
Conversations.get_conversation(scope, id)

# Bad - no authorization
Conversations.get_conversation(id)
```

### 2. Save on Completion

```elixir
# Configure auto-save with on_idle
auto_save: [
  callback: &save/2,
  on_idle: true  # Save when agent becomes idle
]
```

### 3. Handle Missing State Gracefully

```elixir
case Conversations.load_agent_state(id) do
  {:ok, state} ->
    # Restore conversation
    state

  {:error, :not_found} ->
    # Fresh state - this is normal for new conversations
    State.new!()

  {:error, :deserialization_failed} ->
    # Data corruption - log and start fresh
    Logger.error("Failed to deserialize state for #{id}")
    State.new!()
end
```

### 4. Keep Display Messages in Sync

```elixir
# In LiveView
def handle_info({:agent, {:llm_message, message}}, socket) do
  # Save to database
  {:ok, display_msg} = Conversations.append_display_message(
    socket.assigns.conversation_id,
    :assistant,
    message.content
  )

  # Update UI
  {:noreply, update(socket, :messages, &(&1 ++ [display_msg]))}
end
```

### 5. Clean Up Old Conversations

```elixir
# Periodic cleanup job
def cleanup_old_conversations do
  cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

  Conversation
  |> where([c], c.updated_at < ^cutoff)
  |> Repo.delete_all()
end
```
