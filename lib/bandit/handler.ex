defmodule Bandit.Handler do
  @behaviour ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(%ThousandIsland.Connection{} = socket_conn, {plug, plug_opts}) do
    socket_conn
    |> to_plug_conn()
    |> plug.call(plug_opts)
    |> commit_response()

    handle_connection(socket_conn, plug)
  end

  defp to_plug_conn(%ThousandIsland.Connection{} = socket_conn) do
    # TODO - turn socket_conn into a %Plug.Conn{}. Squirrel away
    # any required info inside the `adapter: {Bandit.Conn, %{}}` bit,
    # as the latter part of that is what gets handed back on every request
  end

  defp commit_response(%Plug.Conn{} = conn) do
    # TODO - commit the write if needed
    # TODO - either keepalive or do not, if so commanded
  end
end
