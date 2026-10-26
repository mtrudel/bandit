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
        assert {"banana", ^port} = Headers.parse_hostlike_header!("banana:#{port}")
      end
    end

    test "parses host and port for ipv6 all valid ports" do
      for port <- @valid_ports do
        assert {"[::1]", ^port} = Headers.parse_hostlike_header!("[::1]:#{port}")
      end
    end

    test "parses RFC 3986 uri-host forms" do
      assert {"example.com", nil} = Headers.parse_hostlike_header!("example.com")
      assert {"example%2Ecom", nil} = Headers.parse_hostlike_header!("example%2Ecom")
      assert {"example.com", nil} = Headers.parse_hostlike_header!("example.com:")
      assert {"[2001:db8::1]", nil} = Headers.parse_hostlike_header!("[2001:db8::1]")

      assert {"[v1.example:transport]", nil} =
               Headers.parse_hostlike_header!("[v1.example:transport]")
    end

    test "rejects values outside the RFC 3986 uri-host grammar" do
      for host <- [
            "example.com/path",
            "user@example.com",
            "bad%2",
            "[not-an-ip-literal]",
            "[::1]suffix",
            "2001:db8::1"
          ] do
        assert_raise(Bandit.HTTPError, "Header contains invalid host", fn ->
          Headers.parse_hostlike_header!(host)
        end)
      end
    end

    test "returns error for invalid ports" do
      for port <- @invalid_ports do
        assert_raise(Bandit.HTTPError, @error_msg, fn ->
          Headers.parse_hostlike_header!("banana:#{port}")
        end)
      end
    end

    test "parses ports with leading zeros" do
      assert {"banana", 80} = Headers.parse_hostlike_header!("banana:00080")

      assert {"banana", 80} =
               Headers.parse_hostlike_header!("banana:" <> String.duplicate("0", 10_000) <> "80")
    end

    # GHSA-29cr-8477-rg6r: building a long run of digits into an integer one digit at a time
    # takes quadratic time (several seconds for this value). It must be rejected without that
    test "rejects a port with many digits without converting it" do
      port = String.duplicate("9", 200_000)

      {elapsed_us, _} =
        :timer.tc(fn ->
          assert_raise(Bandit.HTTPError, @error_msg, fn ->
            Headers.parse_hostlike_header!("banana:" <> port)
          end)

          assert_raise(Bandit.HTTPError, @error_msg, fn ->
            Headers.parse_hostlike_header!("[::1]:" <> port)
          end)
        end)

      assert elapsed_us < 100_000
    end

    test "returns error for ipv6 invalid ports" do
      for port <- @invalid_ports do
        assert_raise(Bandit.HTTPError, @error_msg, fn ->
          Headers.parse_hostlike_header!("[::1]:#{port}")
        end)
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

    test "parses the largest values it accepts" do
      header = [{"content-length", "9999999999999999999"}]
      assert Headers.get_content_length(header) == {:ok, 9_999_999_999_999_999_999}
    end

    test "parses values with many leading zeros" do
      header = [{"content-length", String.duplicate("0", 10_000) <> "123"}]
      assert Headers.get_content_length(header) == {:ok, 123}

      header = [{"content-length", String.duplicate("0", 10_000)}]
      assert Headers.get_content_length(header) == {:ok, 0}
    end

    # GHSA-29cr-8477-rg6r: building a long run of digits into an integer one digit at a time
    # takes quadratic time (several seconds for the longest value here). Values with more
    # digits than any usable length must be rejected without that
    test "errors on values with more digits than any usable length, without converting them" do
      for value <- [
            "10000000000000000000",
            String.duplicate("9", 200_000),
            String.duplicate("9", 200_000) <> ", 1",
            "1, " <> String.duplicate("9", 200_000)
          ] do
        header = [{"content-length", value}]
        {elapsed_us, result} = :timer.tc(fn -> Headers.get_content_length(header) end)
        assert {:error, _} = result
        assert elapsed_us < 100_000
      end
    end

    test "errors on invalid integers" do
      for integer <- @invalid_ints do
        header = [{"content-length", integer}]
        assert {:error, _} = Headers.get_content_length(header)
      end
    end
  end

  describe "token_list_member?/2" do
    test "returns false for a nil header value" do
      refute Headers.token_list_member?(nil, "close")
    end

    test "matches a bare single-token value" do
      assert Headers.token_list_member?("close", "close")
      refute Headers.token_list_member?("keep-alive", "close")
    end

    test "matches a token within a comma-separated list, regardless of position" do
      assert Headers.token_list_member?("keep-alive, close", "close")
      assert Headers.token_list_member?("close, keep-alive", "close")
      assert Headers.token_list_member?("keep-alive,close", "close")
    end

    test "compares tokens case-insensitively" do
      assert Headers.token_list_member?("Close", "close")
      assert Headers.token_list_member?("keep-alive, CLOSE", "close")
    end

    test "does not match a token that is only a substring of a list member" do
      refute Headers.token_list_member?("closely", "close")
    end
  end

  describe "header_contains_token?/3" do
    test "returns false when the header is absent" do
      refute Headers.header_contains_token?([], "vary", "accept-encoding")
    end

    test "matches a token within the header's value" do
      assert Headers.header_contains_token?(
               [{"vary", "accept-encoding"}],
               "vary",
               "accept-encoding"
             )

      refute Headers.header_contains_token?(
               [{"vary", "accept-language"}],
               "vary",
               "accept-encoding"
             )
    end

    test "matches the header name case-insensitively" do
      assert Headers.header_contains_token?(
               [{"Vary", "Accept-Encoding"}],
               "vary",
               "accept-encoding"
             )
    end

    test "scans every instance of a repeated header" do
      headers = [{"vary", "accept-language"}, {"vary", "accept-encoding"}]
      assert Headers.header_contains_token?(headers, "vary", "accept-encoding")
    end
  end
end
