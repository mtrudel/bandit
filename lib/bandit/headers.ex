defmodule Bandit.Headers do
  @moduledoc false
  # Conveniences for dealing with headers

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  def get_header(headers, header) do
    case List.keyfind(headers, header, 0) do
      {_, value} -> value
      nil -> nil
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
    with value when not is_nil(value) <- get_header(headers, "content-length"),
         {:ok, length} <- parse_content_length(value) do
      if length >= 0 do
        {:ok, length}
      else
        {:error, "invalid negative content-length header (RFC9110§8.6)"}
      end
    else
      nil -> {:ok, nil}
      error -> error
    end
  end

  defp parse_content_length(value) do
    case Integer.parse(value) do
      {length, ""} ->
        {:ok, length}

      {length, rest} ->
        rest
        |> Plug.Conn.Utils.list()
        |> enforce_unique_value(to_string(length), length)

      :error ->
        {:error, "invalid content-length header (RFC9112§6.3.5)"}
    end
  end

  defp enforce_unique_value([], _str, value), do: {:ok, value}

  defp enforce_unique_value([value | rest], value, int),
    do: enforce_unique_value(rest, value, int)

  defp enforce_unique_value(_values, _value, _int_value),
    do: {:error, "invalid content-length header (RFC9112§6.3.5)"}
end
