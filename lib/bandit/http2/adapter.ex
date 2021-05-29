defmodule Bandit.HTTP2.Adapter do
  @moduledoc false

  defstruct connection: nil, stream_id: nil

  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def read_req_body(%__MODULE__{}, _opts) do
    # TODO receive as needed
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def send_resp(%__MODULE__{} = adapter, status, headers, _body) do
    send_headers(adapter, status, headers)
    # TODO send body
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def send_file(%__MODULE__{} = adapter, status, headers, _path, _offset, _length) do
    send_headers(adapter, status, headers)
    # TODO send file
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def send_chunked(%__MODULE__{} = adapter, status, headers) do
    send_headers(adapter, status, headers)
    # TODO set chunked
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def chunk(%__MODULE__{} = adapter, _chunk) do
    # TODO send body chunk
    {:ok, nil, adapter}
  end

  @impl Plug.Conn.Adapter
  def inform(_req, _status, _headers) do
    # TODO send headers
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def push(_req, _path, _headers) do
    # TODO send PUSH_PROMISE
    {:error, :not_supported}
  end

  @impl Plug.Conn.Adapter
  def get_peer_data(%__MODULE__{}) do
    # TODO ask connection
    nil
  end

  @impl Plug.Conn.Adapter
  def get_http_protocol(%__MODULE__{}), do: :"HTTP/2"

  defp send_headers(adapter, status, headers) do
    headers = [{":status", to_string(status)} | headers]

    # TODO - figure out whether to set end_stream
    GenServer.call(adapter.connection, {:send_headers, adapter.stream_id, headers, false})
  end
end
