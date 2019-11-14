defprotocol Bandit.HTTPRequest do
  @behaviour Plug.Conn.Adapter

  def read_headers(req)

  @impl Plug.Conn.Adapter
  def read_req_body(req, opts)

  @impl Plug.Conn.Adapter
  def send_resp(req, status, headers, response)

  @impl Plug.Conn.Adapter
  def send_file(req, status, headers, path, offset, length)

  @impl Plug.Conn.Adapter
  def send_chunked(req, status, headers)

  @impl Plug.Conn.Adapter
  def chunk(req, chunk)

  @impl Plug.Conn.Adapter
  def inform(req, status, headers)

  @impl Plug.Conn.Adapter
  def push(req, path, headers)

  def get_local_data(req)

  @impl Plug.Conn.Adapter
  def get_peer_data(req)

  @impl Plug.Conn.Adapter
  def get_http_protocol(req)

  def keepalive?(req)
end
