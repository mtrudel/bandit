defmodule Bandit.HeadersTest do
  use ExUnit.Case, async: true

  alias Bandit.Headers

  describe "parse_hostlike_header/1" do
    @valid_ports 0..65_535

    @invalid_ports [
      -999_999_999,
      -1,
      65_536,
      999_999_999,
      "abc123",
      "123abc"
    ]

    @error_msg "Header contains invalid port"

    test "parses host and port for all valid ports" do
      for port <- @valid_ports do
        assert {:ok, "banana", ^port} = Headers.parse_hostlike_header("banana:#{port}")
      end
    end

    test "parses host and port for ipv6 all valid ports" do
      for port <- @valid_ports do
        assert {:ok, "[::1]", ^port} = Headers.parse_hostlike_header("[::1]:#{port}")
      end
    end

    test "returns error for invalid ports" do
      for port <- @invalid_ports do
        assert {:error, @error_msg} = Headers.parse_hostlike_header("banana:#{port}")
      end
    end

    test "returns error for ipv6 invalid ports" do
      for port <- @invalid_ports do
        assert {:error, @error_msg} = Headers.parse_hostlike_header("[::1]:#{port}")
      end
    end
  end

  describe "parse_integer/1" do
    @non_neg_integers ~w[0 1 100 101 420 999999999 0010]
    @neg_integers ~w[-1 -420 -999_999_999 -0010]
    @partial_integers ["123abc", "0-0", "0x01", "3.14", "123 123"]
    @invalid_integers ["abc123", "", " ", " 0", "-123abc"]

    test "parses non-negative integers" do
      for integer <- @non_neg_integers do
        assert Headers.parse_integer(integer) == {String.to_integer(integer), ""}
      end
    end

    test "parses partial integers" do
      for integer <- @partial_integers do
        [num, splitter, rest] = String.split(integer, ~r/[^\d]/, parts: 2, include_captures: true)
        assert Headers.parse_integer(integer) == {String.to_integer(num), splitter <> rest}
      end
    end

    test "errors on negative integers" do
      for integer <- @neg_integers do
        assert :error = Headers.parse_integer(integer)
      end
    end

    test "errors on invalid integers" do
      for integer <- @invalid_integers do
        assert :error = Headers.parse_integer(integer)
      end
    end
  end
end
