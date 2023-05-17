defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers

  def get_header(headers, header) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # covers ipv6 addresses, which look like this: `[::1]:4000` as defined in RFC3986
  def parse_hostlike_header("[" <> _ = host_header) do
    host_header
    |> :binary.split("]:")
    |> case do
      [host, port] ->
        case Integer.parse(port) do
          {port, ""} when port > 0 -> {:ok, host <> "]", port}
          _ -> {:error, "Header contains invalid port"}
        end

      [host] ->
        {:ok, host, nil}
    end
  end

  def parse_hostlike_header(host_header) do
    host_header
    |> :binary.split(":")
    |> case do
      [host, port] ->
        case Integer.parse(port) do
          {port, ""} when port > 0 -> {:ok, host, port}
          _ -> {:error, "Header contains invalid port"}
        end

      [host] ->
        {:ok, host, nil}
    end
  end

  def get_content_length(headers) do
    case get_header(headers, "content-length") do
      nil -> {:ok, nil}
      value -> parse_content_length(value)
    end
  end

  defp parse_content_length(value) do
    case Integer.parse(value) do
      {length, ""} when length >= 0 ->
        {:ok, length}

      {_length, ""} ->
        {:error, "invalid negative content-length header (RFC9110§8.6)"}

      {length, rest} ->
        if rest |> Plug.Conn.Utils.list() |> all?(to_string(length)),
          do: {:ok, length},
          else: {:error, "invalid content-length header (RFC9112§6.3.5)"}

      :error ->
        {:error, "invalid content-length header (RFC9112§6.3.5)"}
    end
  end

  defp all?([value | rest], value), do: all?(rest, value)
  defp all?([], _str), do: true
  defp all?(_values, _value), do: false
end
