defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers.

  @spec is_port_number(integer()) :: Macro.t()
  defguardp is_port_number(port) when Bitwise.band(port, 0xFFFF) === port

  @spec get_header(Plug.Conn.headers(), header :: binary()) :: binary() | nil
  def get_header(headers, header) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # Covers IPv6 addresses, like `[::1]:4000` as defined in RFC3986.
  @spec parse_hostlike_header!(host_header :: binary()) ::
          {Plug.Conn.host(), nil | Plug.Conn.port_number()}
  def parse_hostlike_header!("[" <> _ = host_header) do
    host_header
    |> :binary.split("]:")
    |> case do
      [host, port] ->
        case parse_integer(port) do
          {port, ""} when is_port_number(port) -> {host <> "]", port}
          _ -> raise Bandit.HTTPError, "Header contains invalid port"
        end

      [host] ->
        {host, nil}
    end
  end

  def parse_hostlike_header!(host_header) do
    host_header
    |> :binary.split(":")
    |> case do
      [host, port] ->
        case parse_integer(port) do
          {port, ""} when is_port_number(port) -> {host, port}
          _ -> raise Bandit.HTTPError, "Header contains invalid port"
        end

      [host] ->
        {host, nil}
    end
  end

  @spec get_content_length(Plug.Conn.headers()) ::
          {:ok, nil | non_neg_integer()} | {:error, String.t()}
  def get_content_length(headers) do
    case get_header(headers, "content-length") do
      nil -> {:ok, nil}
      value -> parse_content_length(value)
    end
  end

  @spec parse_content_length(binary()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp parse_content_length(value) do
    case parse_integer(value) do
      {length, ""} ->
        {:ok, length}

      {length, _rest} ->
        if value |> Plug.Conn.Utils.list() |> Enum.all?(&(&1 == to_string(length))),
          do: {:ok, length},
          else: {:error, "invalid content-length header (RFC9112§6.3.5)"}

      :error ->
        {:error, "invalid content-length header (RFC9112§6.3.5)"}
    end
  end

  # Parses non-negative integers from strings. Return the valid portion of an
  # integer and the remaining string as a tuple like `{123, ""}` or `:error`.
  @spec parse_integer(String.t()) :: {non_neg_integer(), rest :: String.t()} | :error
  defp parse_integer(<<digit::8, rest::binary>>) when digit >= ?0 and digit <= ?9 do
    parse_integer(rest, digit - ?0)
  end

  defp parse_integer(_), do: :error

  @spec parse_integer(String.t(), non_neg_integer()) :: {non_neg_integer(), String.t()}
  defp parse_integer(<<digit::8, rest::binary>>, total) when digit >= ?0 and digit <= ?9 do
    parse_integer(rest, total * 10 + digit - ?0)
  end

  defp parse_integer(rest, total), do: {total, rest}

  @spec add_content_length(Plug.Conn.headers(), non_neg_integer(), Plug.Conn.int_status()) ::
          Plug.Conn.headers()
  def add_content_length(headers, length, status) do
    headers = Enum.reject(headers, &(elem(&1, 0) == "content-length"))

    if add_content_length?(status),
      do: [{"content-length", to_string(length)} | headers],
      else: headers
  end

  # Per RFC9110§8.6
  @spec add_content_length?(Plug.Conn.int_status()) :: boolean()
  defp add_content_length?(status) when status in 100..199, do: false
  defp add_content_length?(204), do: false
  defp add_content_length?(304), do: false
  defp add_content_length?(_), do: true
end
