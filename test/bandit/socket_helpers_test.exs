defmodule Bandit.SochetHeadersTest do
  use ExUnit.Case, async: true

  alias Bandit.SocketHelpers, as: SH

  test "iodata_empty?" do
    assert SH.iodata_empty?([])
    assert SH.iodata_empty?("")
    assert SH.iodata_empty?([["", []] | ""])

    refute SH.iodata_empty?([1])
    refute SH.iodata_empty?("1")
    refute SH.iodata_empty?([["", []] | "ok"])
  end
end
