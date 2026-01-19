# Configure Mimic for mocking in tests
Mimic.copy(Req)
Mimic.copy(LangChain.ChatModels.ChatAnthropic)
Mimic.copy(LangChain.ChatModels.ChatOpenAI)

# Start a shared PubSub for tests
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: :test_pubsub)

# Define a real Presence module for tests (no mocks needed)
defmodule Sagents.TestPresence do
  use Phoenix.Presence,
    otp_app: :sagents,
    pubsub_server: :test_pubsub
end

# Start the test Presence (Phoenix.Presence uses Supervisor.start_link/3 internally)
{:ok, _} = Supervisor.start_link([Sagents.TestPresence], strategy: :one_for_one)

Logger.configure(level: :warning)
ExUnit.configure(exclude: [live_call: true])

ExUnit.start(capture_log: true)
