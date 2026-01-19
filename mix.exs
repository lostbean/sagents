defmodule Sagents.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :sagents,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "Sagents",
      description: """
      Agent orchestration framework for Elixir, built on top of LangChain.
      Provides AgentServer, middleware system, state management, and more.
      """
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sagents.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependency - the LangChain library
      {:langchain, path: "../my_langchain"},

      # Required dependencies
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto, "~> 3.10 or ~> 3.11"},

      # Optional dependencies
      {:phoenix, "~> 1.7", optional: true},

      # Test dependencies
      {:mimic, "~> 1.8", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
