defmodule Bandit.WebSocket.Handshake do
  @moduledoc false
  # Functions to support WebSocket handshaking as described in RFC6455§4.2 & RFC7692

  import Plug.Conn

  @type extensions :: [{String.t(), [{String.t(), String.t() | true}]}]

  @spec handshake(Plug.Conn.t(), keyword(), keyword()) ::
          {:ok, Plug.Conn.t(), Keyword.t()} | {:error, String.t()}
  def handshake(%Plug.Conn{} = conn, opts, websocket_opts) do
    with :ok <- Bandit.WebSocket.UpgradeValidation.validate_upgrade(conn) do
      do_handshake(conn, opts, websocket_opts)
    end
  end

  @spec do_handshake(Plug.Conn.t(), keyword(), keyword()) ::
          {:ok, Plug.Conn.t(), keyword()} | {:error, String.t()}
  defp do_handshake(conn, opts, websocket_opts) do
    with {:ok, requested_extensions} <- requested_extensions(conn) do
      {negotiated_params, returned_data} =
        if Keyword.get(opts, :compress) && Keyword.get(websocket_opts, :compress, true) do
          Bandit.WebSocket.PerMessageDeflate.negotiate(requested_extensions, websocket_opts)
        else
          {nil, []}
        end

      conn = send_handshake(conn, returned_data)
      {:ok, conn, Keyword.put(opts, :compress, negotiated_params)}
    end
  end

  # Parses the extension offers per RFC6455§9.1: a comma separated list of extensions, each a
  # name followed by semicolon separated parameters which are either a bare name or name=value.
  # A header that does not fit that grammar (an empty extension name, or a parameter with an
  # empty name or value) is an error, which the caller answers with a 400 rather than a crash
  @spec requested_extensions(Plug.Conn.t()) :: {:ok, extensions()} | {:error, String.t()}
  defp requested_extensions(%Plug.Conn{} = conn) do
    conn
    |> get_req_header("sec-websocket-extensions")
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.reduce_while({:ok, []}, fn extension, {:ok, extensions} ->
      case parse_extension(extension) do
        {:ok, extension} -> {:cont, {:ok, [extension | extensions]}}
        :error -> {:halt, {:error, "Invalid sec-websocket-extensions header (RFC6455§9.1)"}}
      end
    end)
    |> case do
      {:ok, extensions} -> {:ok, Enum.reverse(extensions)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_extension(String.t()) ::
          {:ok, {String.t(), [{String.t(), String.t() | true}]}} | :error
  defp parse_extension(extension) do
    case extension |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [name | params] ->
        with {:ok, params} <- parse_params(params), do: {:ok, {name, params}}

      [] ->
        :error
    end
  end

  @spec parse_params([String.t()]) :: {:ok, [{String.t(), String.t() | true}]} | :error
  defp parse_params(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, params} ->
      case param |> String.split("=", parts: 2) |> Enum.map(&String.trim/1) do
        [key] when key != "" -> {:cont, {:ok, [{key, true} | params]}}
        [key, value] when key != "" and value != "" -> {:cont, {:ok, [{key, value} | params]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      :error -> :error
    end
  end

  @spec send_handshake(Plug.Conn.t(), extensions()) :: Plug.Conn.t()
  defp send_handshake(%Plug.Conn{} = conn, extensions) do
    # Taken from RFC6455§4.2.2/5. Note that we can take for granted the existence of the
    # sec-websocket-key header in the request, since we check for it in the handshake? call above
    [client_key] = get_req_header(conn, "sec-websocket-key")
    concatenated_key = client_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    hashed_key = :crypto.hash(:sha, concatenated_key)
    server_key = Base.encode64(hashed_key)

    headers =
      [
        {:upgrade, "websocket"},
        {:connection, "Upgrade"},
        {:"sec-websocket-accept", server_key}
      ] ++
        websocket_extension_header(extensions) ++
        conn.resp_headers

    inform(conn, 101, headers)
  end

  @spec websocket_extension_header(extensions()) :: keyword()
  defp websocket_extension_header([]), do: []

  defp websocket_extension_header(extensions) do
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

    [{:"sec-websocket-extensions", extensions}]
  end
end
