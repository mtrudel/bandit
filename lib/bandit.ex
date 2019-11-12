defmodule Bandit do
  @moduledoc """
  Defines a Bandit server as part of a supervision tree. A typical child spec
  to start a Bandit server hosting a plug looks like:

  ```
  {Bandit, plug: {MyApp.Plug, :arg_passed_to_plug_init}, opts: [port: 4000]}
  ```

  The third argument allows for the following options: 

  `port`: The port to bind to. Defaults to 4000
  `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
  tuning knob and can usually be left at the default value of 10
  `transport_options`: A keyword list of options to be passed into the listener socket
  """

  def child_spec(arg) do
    {opts, illegal_opts} =
      arg
      |> Keyword.get(:opts, [])
      |> Keyword.split(~w(port num_acceptors transport_options)a)

    if illegal_opts != [] do
      raise "Unsupported option(s) in Bandit config: #{inspect(illegal_opts)}"
    end

    opts =
      opts
      |> Keyword.put(:handler_module, Bandit.Handler)
      |> Keyword.put(:handler_opts, plug(arg))

    %{
      id: Bandit,
      start: {ThousandIsland.Server, :start_link, [opts]}
    }
  end

  defp plug(arg) do
    arg
    |> Keyword.fetch!(:plug)
    |> case do
      {plug, plug_opts} -> {plug, plug.init(plug_opts)}
      plug -> {plug, plug.init([])}
    end
  end
end
