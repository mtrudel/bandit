defmodule SimpleHTTP1Client do
  @moduledoc false

  def tcp_client(context) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", context[:port], active: false, mode: :binary, nodelay: true)

    socket
  end

  def tls_client(context, protocols) do
    {:ok, socket} =
      :ssl.connect(~c"localhost", context[:port],
        active: false,
        mode: :binary,
        nodelay: true,
        verify: :verify_peer,
        cacertfile: Path.join(__DIR__, "../support/ca.pem"),
        alpn_advertised_protocols: protocols
      )

    socket
  end

  def send(socket, verb, request_target, headers \\ [], version \\ "1.1") do
    :gen_tcp.send(socket, "#{verb} #{request_target} HTTP/#{version}\r\n")
    Enum.each(headers, &:gen_tcp.send(socket, &1 <> "\r\n"))
    :gen_tcp.send(socket, "\r\n")
  end

  def recv_reply(socket) do
    {:ok, response} = :gen_tcp.recv(socket, 0)
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
        nil ->
          rest

        value ->
          case String.to_integer(value) - byte_size(rest) do
            0 ->
              rest

            pending ->
              {:ok, response} = :gen_tcp.recv(socket, pending)
              rest <> response
          end
      end

    {:ok, status, headers, body}
  end

  def connection_closed_for_reading?(client) do
    :gen_tcp.recv(client, 0) == {:error, :closed}
  end
end
