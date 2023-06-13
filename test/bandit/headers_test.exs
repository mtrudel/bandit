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

  describe "get_content_length/1" do
    @non_neg_ints ~w[0 1 100 101 420 999999999 0010]
    @neg_ints ~w[-1 -420 -999_999_999 -0010]
    @repeat_ints ["123, 123", "234,234"]
    @repeat_ints_ows ["345  , ,  345 ,345,345"]
    @invalid_repeat_ints ["123, 124", "234 , 235, 235", "345 345"]
    @partial_ints ["123abc", "0-0", "0x01", "3.14"]
    @invalid_ints ["abc123", "", " ", " 0", "-123abc"]

    test "parses non-negative integers" do
      for integer <- @non_neg_ints do
        header = [{"content-length", integer}]
        assert Headers.get_content_length(header) == {:ok, String.to_integer(integer)}
      end
    end

    test "parses repeat integers" do
      for integer <- @repeat_ints do
        [num, _] = String.split(integer, ~r/[^\d]/, parts: 2)
        header = [{"content-length", integer}]
        assert Headers.get_content_length(header) == {:ok, String.to_integer(num)}
      end
    end

    # Skipping this until a release of Plug is available with this PR:
    # https://github.com/elixir-plug/plug/pull/1155
    @tag :skip
    test "parses repeat integers with optional whitespace" do
      for integer <- @repeat_ints_ows do
        [num, _] = String.split(integer, ~r/[^\d]/, parts: 2)
        header = [{"content-length", integer}]
        assert Headers.get_content_length(header) == {:ok, String.to_integer(num)}
      end
    end

    test "errors on non-matching repeat integers" do
      for integer <- @invalid_repeat_ints do
        header = [{"content-length", integer}]
        assert {:error, _} = Headers.get_content_length(header)
      end
    end

    test "errors on partial integers" do
      for integer <- @partial_ints do
        header = [{"content-length", integer}]
        assert {:error, _} = Headers.get_content_length(header)
      end
    end

    test "errors on negative integers" do
      for integer <- @neg_ints do
        header = [{"content-length", integer}]
        assert {:error, _} = Headers.get_content_length(header)
      end
    end

    test "errors on invalid integers" do
      for integer <- @invalid_ints do
        header = [{"content-length", integer}]
        assert {:error, _} = Headers.get_content_length(header)
      end
    end
  end
end
