defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers

  @spec is_port_number(integer()) :: Macro.t()
  defguardp is_port_number(port) when Bitwise.band(port, 0xFFFF) === port

  @spec get_header(Plug.Conn.headers(), header :: binary()) :: binary() | nil
  def get_header(headers, header) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # covers ipv6 addresses, which look like this: `[::1]:4000` as defined in RFC3986
  @spec parse_hostlike_header(host_header :: binary()) ::
          {:ok, binary(), nil | integer()} | {:error, String.t()}
  def parse_hostlike_header("[" <> _ = host_header) do
    host_header
    |> :binary.split("]:")
    |> case do
      [host, port] ->
        case Integer.parse(port) do
          {port, ""} when is_port_number(port) -> {:ok, host <> "]", port}
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
          {port, ""} when is_port_number(port) -> {:ok, host, port}
          _ -> {:error, "Header contains invalid port"}
        end

      [host] ->
        {:ok, host, nil}
    end
  end

  @spec get_content_length(Plug.Conn.headers()) :: {:ok, nil | integer()} | {:error, String.t()}
  def get_content_length(headers) do
    case get_header(headers, "content-length") do
      nil -> {:ok, nil}
      value -> parse_content_length(value)
    end
  end

  @spec parse_content_length(binary()) :: {:ok, length :: integer()} | {:error, String.t()}
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

  @spec all?([binary()], binary()) :: boolean()
  defp all?([value | rest], value), do: all?(rest, value)
  defp all?([], _str), do: true
  defp all?(_values, _value), do: false
end
