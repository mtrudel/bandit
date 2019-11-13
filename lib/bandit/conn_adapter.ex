defmodule Bandit.ConnAdapter do
  @behaviour Plug.Conn.Adapter

  alias Bandit.HTTPRequest
  alias Plug.Conn

  def conn(%HTTPRequest{} = req) do
    case HTTPRequest.read_headers(req) do
      {:ok, headers, req} ->
        {{_, local_port}, {remote_ip, _}} = HTTPRequest.get_endpoints(req)

        # TODO read path / query string etc

        {:ok,
         %Conn{
           adapter: {__MODULE__, req},
           owner: self(),
           remote_ip: remote_ip,
           port: local_port,
           req_headers: headers,
           method: to_string(req.method)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # TODO revisit the various delegation / protocol options here & harmonize

  @impl true
  defdelegate read_req_body(req, opts), to: HTTPRequest

  @impl true
  defdelegate send_resp(req, status, headers, body), to: HTTPRequest

  @impl true
  defdelegate send_file(req, status, headers, path, offset, length), to: HTTPRequest

  @impl true
  defdelegate send_chunked(req, status, headers), to: HTTPRequest

  @impl true
  defdelegate chunk(req, chunk), to: HTTPRequest

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
    {_, {remote_ip, remote_port}} = HTTPRequest.get_endpoints(req)
    %{address: remote_ip, port: remote_port, ssl_cert: nil}
  end

  @impl true
  def get_http_protocol(req), do: req.version
end
