defmodule Bandit.WebSocket.UpgradeValidation do
  @moduledoc false
  # Provides validation of WebSocket upgrade requests as described in RFC6455§4.2

  # Validates that the request satisfies the requirements to issue a WebSocket upgrade response.
  # Validations are performed based on the clauses laid out in RFC6455§4.2
  #
  # This function does not actually perform an upgrade or change the connection in any way
  #
  # Returns `:ok` if the connection satisfies the requirements for a WebSocket upgrade, and
  # `{:error, reason}` if not
  #
  @spec validate_upgrade(Plug.Conn.t()) :: :ok | {:error, String.t()}
  def validate_upgrade(conn) do
    case Plug.Conn.get_http_protocol(conn) do
      :"HTTP/1.1" -> validate_upgrade_http1(conn)
      other -> {:error, "HTTP version #{other} unsupported"}
    end
  end

  # Validate the conn per RFC6455§4.2.1
  defp validate_upgrade_http1(conn) do
    with :ok <- assert_method(conn, "GET"),
         :ok <- assert_header_nonempty(conn, "host"),
         :ok <- assert_header_contains(conn, "connection", "upgrade"),
         :ok <- assert_header_contains(conn, "upgrade", "websocket"),
         :ok <- assert_header_nonempty(conn, "sec-websocket-key"),
         :ok <- assert_header_equals(conn, "sec-websocket-version", "13") do
      :ok
    end
  end

  defp assert_method(conn, verb) do
    case conn.method do
      ^verb -> :ok
      other -> {:error, "HTTP method #{other} unsupported"}
    end
  end

  defp assert_header_nonempty(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] -> {:error, "'#{header}' header is absent"}
      _ -> :ok
    end
  end

  defp assert_header_equals(conn, header, expected) do
    case Plug.Conn.get_req_header(conn, header) |> Enum.map(&String.downcase(&1, :ascii)) do
      [^expected] -> :ok
      value -> {:error, "'#{header}' header must equal '#{expected}', got #{inspect(value)}"}
    end
  end

  defp assert_header_contains(conn, header, needle) do
    haystack = Plug.Conn.get_req_header(conn, header)

    haystack
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.any?(&(String.downcase(&1, :ascii) == needle))
    |> case do
      true -> :ok
      false -> {:error, "'#{header}' header must contain '#{needle}', got #{inspect(haystack)}"}
    end
  end
end
