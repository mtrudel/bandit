defmodule Bandit.ConnBuilder do
  alias Bandit.Private

  def build(%ThousandIsland.Connection{} = socket_conn) do
    %Plug.Conn{
      adapter: {Bandit.Conn, %Private{socket: socket_conn}},
      owner: self()
    }
    |> parse_endpoints()
    |> parse_http()
  end

  defp parse_endpoints(%Plug.Conn{adapter: {_, priv}} = conn) do
    {{_, local_port}, {remote_ip, _}} = ThousandIsland.Connection.endpoints(priv.socket)
    %{conn | remote_ip: remote_ip, port: local_port}
  end

  defp parse_http(%Plug.Conn{adapter: {_, _priv}} = conn) do
    # TODO http parsing from erlang (for now)
    conn
  end
end
