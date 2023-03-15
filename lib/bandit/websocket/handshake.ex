defmodule Bandit.WebSocket.Handshake do
  @moduledoc false
  # Functions to support WebSocket handshaking as described in RFC6455§4.2 & RFC7692

  import Plug.Conn

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  def valid_upgrade?(%Plug.Conn{} = conn) do
    case get_http_protocol(conn) do
      :"HTTP/1.1" ->
        # Cases from RFC6455§4.2.1
        conn.method == "GET" and
          get_req_header(conn, "host") != [] and
          header_contains?(conn, "upgrade", "websocket") and
          header_contains?(conn, "connection", "upgrade") and
          match?([<<_::binary>>], get_req_header(conn, "sec-websocket-key")) and
          get_req_header(conn, "sec-websocket-version") == ["13"]

      _ ->
        false
    end
  end

  def handshake(%Plug.Conn{} = conn, opts, websocket_opts) do
    if valid_upgrade?(conn) do
      do_handshake(conn, opts, websocket_opts)
    else
      {:error, "Not a valid WebSocket upgrade request"}
    end
  end

  defp do_handshake(conn, opts, websocket_opts) do
    requested_extensions = requested_extensions(conn)

    {negotiated_params, returned_data} =
      if Keyword.get(opts, :compress) && Keyword.get(websocket_opts, :compress, true) do
        Bandit.WebSocket.PerMessageDeflate.negotiate(requested_extensions)
      else
        {nil, []}
      end

    conn = send_handshake(conn, returned_data)
    {:ok, conn, Keyword.put(opts, :compress, negotiated_params)}
  end

  defp requested_extensions(%Plug.Conn{} = conn) do
    conn
    |> get_req_header("sec-websocket-extensions")
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.map(fn extension ->
      [name | params] =
        extension
        |> String.split(";", trim: true)
        |> Enum.map(&String.trim/1)

      params = split_params(params)

      {name, params}
    end)
  end

  defp split_params(params) do
    params
    |> Enum.map(fn param ->
      param
      |> String.split("=", trim: true)
      |> Enum.map(&String.trim/1)
      |> case do
        [key, value] -> {key, value}
        [key] -> {key, true}
      end
    end)
  end

  defp send_handshake(%Plug.Conn{} = conn, extensions) do
    # Taken from RFC6455§4.2.2/5. Note that we can take for granted the existence of the
    # sec-websocket-key header in the request, since we check for it in the handshake? call above
    [client_key] = get_req_header(conn, "sec-websocket-key")
    concatenated_key = client_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    hashed_key = :crypto.hash(:sha, concatenated_key)
    server_key = Base.encode64(hashed_key)

    conn
    |> resp(101, "")
    |> put_resp_header("upgrade", "websocket")
    |> put_resp_header("connection", "Upgrade")
    |> put_resp_header("sec-websocket-accept", server_key)
    |> put_websocket_extension_header(extensions)
    |> send_resp()
  end

  defp put_websocket_extension_header(conn, []), do: conn

  defp put_websocket_extension_header(conn, extensions) do
    extensions =
      extensions
      |> Enum.map_join(",", fn {extension, params} ->
        params =
          params
          |> Enum.flat_map(fn
            {_param, false} -> []
            {param, true} -> [to_string(param)]
            {param, value} -> [to_string(param) <> "=" <> to_string(value)]
          end)

        [to_string(extension) | params]
        |> Enum.join(";")
      end)

    put_resp_header(conn, "sec-websocket-extensions", extensions)
  end

  defp header_contains?(conn, field, value) do
    value = String.downcase(value, :ascii)

    conn
    |> get_req_header(field)
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.any?(&(String.downcase(&1, :ascii) == value))
  end
end
