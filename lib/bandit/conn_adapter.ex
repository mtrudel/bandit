defmodule Bandit.ConnAdapter do
  @behaviour Plug.Conn.Adapter

  alias Bandit.HTTPRequest
  alias Plug.Conn

  def conn(%HTTPRequest{} = req) do
    {{_, local_port}, {remote_ip, _}} = HTTPRequest.endpoints(req)

    # TODO read verb, path, headers

    %Conn{
      adapter: {__MODULE__, req},
      owner: self(),
      remote_ip: remote_ip,
      port: local_port
    }
  end

  @impl true
  def send_resp(req, status, headers, body) do
    req = HTTPRequest.send_resp(req, status, headers, body)
    {:ok, nil, req}
  end

  @impl true
  def send_file(req, status, headers, path, offset, length) do
    req = HTTPRequest.send_file(req, status, headers, path, offset, length)
    {:ok, nil, req}
  end

  @impl true
  def send_chunked(req, status, headers) do
    req = HTTPRequest.send_chunked(req, status, headers)
    {:ok, nil, req}
  end

  @impl true
  def chunk(req, chunk) do
    req = HTTPRequest.send_chunk(req, chunk)
    {:ok, nil, req}
  end

  @impl true
  def read_req_body(req, opts) do
    req = HTTPRequest.read_body(req, opts)
    {:ok, nil, req}
  end

  @impl true
  def inform(_req, _status, _headers) do
    {:error, :not_supported}
  end

  @impl true
  def push(_req, _path, _headers) do
    {:error, :not_supported}
  end

  @impl true
  def get_peer_data(req) do
    {_, {remote_ip, remote_port}} = HTTPRequest.endpoints(req)
    %{address: remote_ip, port: remote_port, ssl_cert: nil}
  end

  @impl true
  def get_http_protocol(req), do: HTTPRequest.version(req)
end
