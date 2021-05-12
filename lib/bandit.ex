defmodule Bandit do
  @moduledoc """
  Defines a Bandit server as part of a supervision tree. A typical child spec
  to start a Bandit server hosting a plug looks like:

  ```
  {Bandit, plug: {MyApp.Plug, :arg_passed_to_plug_init}, options: [port: 4000]}
  ```

  Three options are supported:

  * `scheme`: One of `:http` or `:https`. If `:https` is supported, you will need
     to specify `certfile` and `keyfile` in the `transport_options` subsection of `options`.
  * `plug`: The plug to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `options`: Options to pass to `ThousandIsland`. For an exhaustive list of options see the 
    `ThousandIsland` documentation, however some common options are:
      * `port`: The port to bind to. Defaults to 4000
      * `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
      tuning knob and can usually be left at the default value of 10
      * `transport_module`: The name of the module which provides basic socket functions.
      This overrides any value set for `scheme` and is intended for cases where control
      over the socket at a fundamental level is needed.
      * `transport_options`: A keyword list of options to be passed into the transport socket's listen function
  """

  def child_spec(arg) do
    {options, illegal_options} =
      arg
      |> Keyword.get(:options, [])
      |> Keyword.split(~w(port num_acceptors transport_module transport_options)a)

    if illegal_options != [] do
      raise "Unsupported option(s) in Bandit config: #{inspect(illegal_options)}"
    end

    {transport_module, extra_transport_options} =
      case Keyword.get(arg, :scheme, :http) do
        :http -> {ThousandIsland.Transports.TCP, []}
        :https -> {ThousandIsland.Transports.SSL, alpn_preferred_protocols: ["h2", "http/1.1"]}
      end

    options =
      options
      |> Keyword.put_new(:transport_module, transport_module)
      |> Keyword.update(
        :transport_options,
        extra_transport_options,
        &Keyword.merge(&1, extra_transport_options)
      )
      |> Keyword.put(:handler_module, Bandit.DelegatingHandler)
      |> Keyword.put(:handler_options, %{plug: plug(arg), handler_module: Bandit.InitialHandler})

    %{id: Bandit, start: {ThousandIsland, :start_link, [options]}}
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
