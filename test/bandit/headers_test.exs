defmodule Bandit.HeadersTest do
  use ExUnit.Case, async: true

  alias Bandit.Headers

  @valid_ports 0..65_535

  @invalid_ports [
    -999_999_999,
    -1,
    65_536,
    999_999_999,
    "abc123",
    "123abc"
  ]

  describe "parse_hostlike_header/1" do
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
end
