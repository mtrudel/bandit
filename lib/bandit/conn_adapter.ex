defmodule Bandit.ConnAdapter do
  @behaviour Plug.Conn.Adapter

  @impl true
  def send_resp(req, status, headers, body) do
  end

  @impl true
  def send_file(req, status, headers, path, offset, length) do
  end

  @impl true
  def send_chunked(req, status, headers) do
  end

  @impl true
  def chunk(req, body) do
  end

  @impl true
  def read_req_body(req, opts) do
  end

  @impl true
  def inform(req, status, headers) do
    {:error, :not_supported}
  end

  @impl true
  def push(req, path, headers) do
    {:error, :not_supported}
  end

  @impl true
  def get_peer_data(req) do
  end

  @impl true
  def get_http_protocol(req) do
  end
end
