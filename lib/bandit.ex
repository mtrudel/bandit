defmodule Bandit do
  @moduledoc """
  Defines a Bandit server as part of a supervision tree. A typical child spec
  to start a Bandit server hosting a plug looks like:

  ```
  {Bandit, plug: {MyApp.Plug, :arg_passed_to_plug_init}, options: [port: 4000]}
  ```

  Three options are supported:

  * `scheme`: Currently only `:http` is supported
  * `plug`: The plug to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `options`: Options to pass to `ThousandIsland.Server`. For an exhaustive list of options see the 
    `ThousandIsland.Server` documentation, however some common options are:
      * `port`: The port to bind to. Defaults to 4000
      * `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
      tuning knob and can usually be left at the default value of 10
      * `transport_options`: A keyword list of options to be passed into the transport socket's listen function
  """

  def child_spec(arg) do
    {options, illegal_options} =
      arg
      |> Keyword.get(:options, [])
      |> Keyword.split(~w(port num_acceptors transport_options)a)

    if illegal_options != [] do
      raise "Unsupported option(s) in Bandit config: #{inspect(illegal_options)}"
    end

    options =
      options
      |> Keyword.put(:handler_module, Bandit.Handler)
      |> Keyword.put(:handler_options, plug(arg))

    %{
      id: Bandit,
      start: {ThousandIsland.Server, :start_link, [options]}
    }
  end

  defp plug(arg) do
    arg
    |> Keyword.fetch!(:plug)
    |> case do
      {plug, plug_options} -> {plug, plug.init(plug_options)}
      plug -> {plug, plug.init([])}
    end
  end
end
