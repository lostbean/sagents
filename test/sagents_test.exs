defmodule SagentsTest do
  use ExUnit.Case
  doctest Sagents

  test "greets the world" do
    assert Sagents.hello() == :world
  end
end
