defmodule Bandit.HTTPParser do
  alias ThousandIsland.Socket

  # TODO - this should broker in HTTPRequests
  def parse_headers(
        %Socket{} = socket,
        type \\ :http,
        {version, method, path, headers, data} \\ {nil, nil, nil, [], ""}
      ) do
    case :erlang.decode_packet(type, data, []) do
      {:ok, {:http_request, method, {:abs_path, path}, {http_major, http_minor}}, rest} ->
        parse_headers(socket, :httph, {version(http_major, http_minor), method, path, headers, rest})

      {:ok, {:http_header, _, header, _, value}, rest} ->
        parse_headers(socket, :httph, {version, method, path, [{header, value} | headers], rest})

      {:ok, :http_eoh, rest} ->
        {:ok, version, method, path, headers, rest}

      {:more, _len} ->
        case Socket.recv(socket) do
          {:ok, more_data} -> parse_headers(socket, type, {version, method, path, headers, data <> more_data})
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp version(1, 1), do: "HTTP/1.1"
  defp version(1, 0), do: "HTTP/1.0"
end
