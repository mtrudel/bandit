defmodule SimpleHTTP1Client do
  @moduledoc false

  defdelegate tcp_client(context), to: Transport

  def send(socket, verb, request_target, headers \\ [], version \\ "1.1") do
    Transport.send(socket, "#{verb} #{request_target} HTTP/#{version}\r\n")
    Enum.each(headers, &Transport.send(socket, &1 <> "\r\n"))
    Transport.send(socket, "\r\n")
  end

  def recv_reply(socket, head? \\ false) do
    {:ok, response} = Transport.recv(socket, 0)
    parse_response(socket, response, head?)
  end

  def parse_response(socket, response, head? \\ false) do
    [status_line | headers] = String.split(response, "\r\n")
    <<_version::binary-size(8), " ", status::binary>> = status_line
    {headers, rest} = Enum.split_while(headers, &(&1 != ""))

    headers =
      Enum.map(headers, fn header ->
        [key, value] = String.split(header, ":", parts: 2)
        {String.to_atom(key), String.trim(value)}
      end)

    rest = rest |> Enum.drop(1) |> Enum.join("\r\n")

    body =
      headers
      |> Keyword.get(:"content-length")
      |> case do
        _ when head? ->
          rest

        nil ->
          rest

        value ->
          case String.to_integer(value) - byte_size(rest) do
            0 ->
              rest

            pending when pending < 0 ->
              expected = String.to_integer(value)
              <<response::binary-size(expected), _rest::binary>> = rest
              response

            pending ->
              {:ok, response} = Transport.recv(socket, pending)
              rest <> response
          end
      end

    {:ok, status, headers, body}
  end

  def connection_closed_for_reading?(client) do
    Transport.recv(client, 0) == {:error, :closed}
  end
end
