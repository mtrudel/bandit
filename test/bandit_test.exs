defmodule BanditTest do
  use ExUnit.Case
  doctest Bandit

  test "greets the world" do
    assert Bandit.hello() == :world
  end
end
