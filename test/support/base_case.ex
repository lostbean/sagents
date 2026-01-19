defmodule Sagents.BaseCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that use Sagents features like Agents or AgentServer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias LangChain.Message
      alias LangChain.MessageDelta

      # Import conveniences for testing
      import Sagents.BaseCase
      import Sagents.TestingHelpers

      @doc """
      Helper function for loading an image as base64 encoded text.
      """
      def load_image_base64(filename) do
        Path.join("./test/support/images", filename)
        |> File.read!()
        |> :base64.encode()
      end
    end
  end
end
