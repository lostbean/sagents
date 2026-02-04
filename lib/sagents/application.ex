defmodule Sagents.Application do
  @moduledoc """
  The Sagents OTP Application.

  Starts the core infrastructure for Sagents:
  - Registry for process registration and discovery
  - AgentsDynamicSupervisor for managing agent lifecycles
  - FileSystemSupervisor for managing filesystem instances

  Note: Applications using Sagents do not need to start FileSystemSupervisor
  themselves - it's included here for convenience.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for process registration and discovery
      {Registry, keys: :unique, name: Sagents.Registry},

      # DynamicSupervisor for managing AgentSupervisor instances
      {Sagents.AgentsDynamicSupervisor, name: Sagents.AgentsDynamicSupervisor},

      # DynamicSupervisor for managing FileSystemServer instances
      {Sagents.FileSystem.FileSystemSupervisor, name: Sagents.FileSystem.FileSystemSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Sagents.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
