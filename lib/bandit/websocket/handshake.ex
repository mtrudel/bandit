defmodule Bandit.WebSocket.Handshake do
  @moduledoc false
  # Functions to support WebSocket handshaking as described in RFC6455§4.2 & RFC7692

  import Plug.Conn

  @type extensions :: [{String.t(), [{String.t(), String.t() | true}]}]

  @spec valid_upgrade?(Plug.Conn.t()) :: boolean()
  def valid_upgrade?(%Plug.Conn{} = conn) do
    validate_upgrade(conn) == :ok
  end

  @spec validate_upgrade(Plug.Conn.t()) :: :ok | {:error, String.t()}
  defp validate_upgrade(conn) do
    # Cases from RFC6455§4.2.1
    with {:http_version, :"HTTP/1.1"} <- {:http_version, get_http_protocol(conn)},
         {:method, "GET"} <- {:method, conn.method},
         {:host_header, header} when header != [] <- {:host_header, get_req_header(conn, "host")},
         {:upgrade_header, true} <-
           {:upgrade_header, header_contains(conn, "upgrade", "websocket")},
         {:connection_header, true} <-
           {:connection_header, header_contains(conn, "connection", "upgrade")},
         {:sec_websocket_key_header, true} <-
           {:sec_websocket_key_header,
            match?([<<_::binary>>], get_req_header(conn, "sec-websocket-key"))},
         {:sec_websocket_version_header, ["13"]} <-
           {:sec_websocket_version_header, get_req_header(conn, "sec-websocket-version")} do
      :ok
    else
      {step, detail} ->
        {:error, "WebSocket upgrade failed: error in #{step} check: #{inspect(detail)}"}
    end
  end

  @spec handshake(Plug.Conn.t(), keyword(), keyword()) ::
          {:ok, Plug.Conn.t(), Keyword.t()} | {:error, String.t()}
  def handshake(%Plug.Conn{} = conn, opts, websocket_opts) do
    with :ok <- validate_upgrade(conn) do
      do_handshake(conn, opts, websocket_opts)
    end
  end

  @spec do_handshake(Plug.Conn.t(), keyword(), keyword()) :: {:ok, Plug.Conn.t(), keyword()}
  defp do_handshake(conn, opts, websocket_opts) do
    requested_extensions = requested_extensions(conn)

    {negotiated_params, returned_data} =
      if Keyword.get(opts, :compress) && Keyword.get(websocket_opts, :compress, true) do
        Bandit.WebSocket.PerMessageDeflate.negotiate(requested_extensions, websocket_opts)
      else
        {nil, []}
      end

    conn = send_handshake(conn, returned_data)
    {:ok, conn, Keyword.put(opts, :compress, negotiated_params)}
  end

  @spec requested_extensions(Plug.Conn.t()) :: extensions()
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

  @spec split_params([String.t()]) :: [{String.t(), String.t() | true}]
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

  @spec send_handshake(Plug.Conn.t(), extensions()) :: Plug.Conn.t()
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

  @spec put_websocket_extension_header(Plug.Conn.t(), extensions()) :: Plug.Conn.t()
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

  @spec header_contains(Plug.Conn.t(), field :: String.t(), value :: String.t()) ::
          true | binary()
  defp header_contains(conn, field, value) do
    downcase_value = String.downcase(value, :ascii)
    header = get_req_header(conn, field)

    header
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.any?(&(String.downcase(&1, :ascii) == downcase_value))
    |> case do
      true -> true
      false -> "Did not find '#{value}' in '#{header}'"
    end
  end
end
