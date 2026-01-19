defmodule Sagents.Application do
  @moduledoc """
  The Sagents OTP Application.

  Starts the Registry used for agent process registration.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Sagents.Registry}
    ]

    opts = [strategy: :one_for_one, name: Sagents.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
