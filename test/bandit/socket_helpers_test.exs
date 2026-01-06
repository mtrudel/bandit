defmodule Bandit.SochetHeadersTest do
  use ExUnit.Case, async: true

  test "iodata_empty?" do
    assert Bandit.SocketHelpers.iodata_empty?([])
    assert Bandit.SocketHelpers.iodata_empty?("")
    assert Bandit.SocketHelpers.iodata_empty?([["", []] | ""])

    refute Bandit.SocketHelpers.iodata_empty?([1])
    refute Bandit.SocketHelpers.iodata_empty?("1")
    refute Bandit.SocketHelpers.iodata_empty?([["", []] | "ok"])
  end
end
