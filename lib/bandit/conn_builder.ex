defmodule Bandit.ConnBuilder do
  alias Bandit.Private

  alias ThousandIsland.Socket
  alias Plug.Conn

  def build(%Socket{} = socket_conn) do
    %Conn{
      adapter: {Bandit.ConnAdapter, %Private{socket: socket_conn}},
      owner: self()
    }
    |> parse_endpoints()
    |> parse_http()
  end

  defp parse_endpoints(%Conn{adapter: {_, priv}} = conn) do
    {{_, local_port}, {remote_ip, _}} = Socket.endpoints(priv.socket)
    %{conn | remote_ip: remote_ip, port: local_port}
  end

  defp parse_http(%Conn{adapter: {_, _priv}} = conn) do
    # TODO http parsing from erlang (for now)
    conn
  end
end
