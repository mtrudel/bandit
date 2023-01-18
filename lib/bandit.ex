defmodule Bandit do
  @moduledoc """
  Bandit is an HTTP server for Plug and WebSock apps.

  As an HTTP server, Bandit's primary goal is to act as 'glue' between client connections managed
  by [Thousand Island](https://github.com/mtrudel/thousand_island) and application code defined
  via the [Plug](https://github.com/elixir-plug/plug) and/or
  [WebSock](https://github.com/phoenixframework/websock) APIs. As such there really isn't a whole lot of
  user-visible surface area to Bandit, and as a consequence the API documentation presented here
  is somewhat sparse. This is by design! Bandit is intended to 'just work' in almost all cases;
  the only thought users typically have to put into Bandit comes in the choice of which options (if
  any) they would like to change when starting a Bandit server. The sparseness of the Bandit API
  should not be taken as an indicator of the comprehensiveness or robustness of the project.

  ## Using Bandit With Phoenix

  Bandit fully supports Phoenix. Phoenix applications which use WebSockets for
  features such as Channels or LiveView require Phoenix 1.7 or later.

  Using Bandit to host your Phoenix application couldn't be simpler:

  1. Add Bandit as a dependency in your Phoenix application's `mix.exs`:
    ```elixir
    {:bandit, ">= 0.5.10"}
    ```

  2. Add the following to your endpoint configuration in `config/config.exs`:
    ```elixir
    config :your_app, YourAppWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter
    ```

  3. That's it! You should now see messages at startup indicating that Phoenix is using Bandit to
  serve your endpoint.

  For more details about how to configure Bandit within Phoenix, consult the
  `Bandit.PhoenixAdapter` documentation.

  ## Using Bandit With Plug Applications

  Using Bandit to host your own Plug is very straightforward. Assuming you have a Plug module
  implemented already, you can host it within Bandit by adding something similar to the following
  to your application's `Application.start/2` function:

  ```elixir
  def start(_type, _args) do
    children = [
      {Bandit, plug: MyApp.MyPlug, scheme: :http, options: [port: 4000]}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  For details about writing Plug based applications, consult the excellent [Plug
  documentation](https://hexdocs.pm/plug/) for plenty of examples & tips to get started.
  Bandit supports the complete Plug API & should work correctly with any Plug-based
  application. If you encounter errors using Bandit your Plug app, please do get in touch by
  filing an issue on the Bandit GitHub project (especially if the error does not occur with
  another HTTP server such as Cowboy).

  ## Config Options

  Bandit takes a number of options at startup:

  * `plug`: The plug to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `display_plug`: The plug to use when describing the connection in logs. Useful for situations
    such as Phoenix code reloading where you have a 'wrapper' plug but wish to refer to the
    connection by the endpoint name
  * `scheme`: One of `:http` or `:https`. If `:https` is specified, you will need
     to specify `certfile` and `keyfile` in the `transport_options` subsection of `options`.
  * `options`: Options to pass to `ThousandIsland`. For an exhaustive list of options see the
    `ThousandIsland` documentation, however some common options are:
      * `port`: The port to bind to. Defaults to 4000
      * `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
      tuning knob and can usually be left at the default value of 10
      * `read_timeout`: How long to wait for data from the client before timing out and closing the
      connection, specified in milliseconds. Defaults to `15_000` milliseconds
      * `transport_module`: The name of the module which provides basic socket functions.
      This overrides any value set for `scheme` and is intended for cases where control
      over the socket at a fundamental level is needed.
      * `transport_options`: A keyword list of options to be passed into the transport socket's listen function

  ## Setting up an HTTPS Server

  By far the most common stumbling block encountered with configuration involves setting up an
  HTTPS server.  Bandit is comparatively easy to set up in this regard, with a working example
  looking similar to the following:

  ```elixir
  def start(_type, _args) do
    bandit_options = [
      port: 4000,
      transport_options: [
        certfile: Path.join(__DIR__, "path/to/cert.pem"),
        keyfile: Path.join(__DIR__, "path/to/key.pem")
      ]
    ]

    children = [
      {Bandit, plug: MyApp.MyPlug, scheme: :https, options: bandit_options}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  ## WebSocket Support

  Bandit supports upgrading HTTP requests to WebSocket connections via 
  the use of the `Plug.Conn.upgrade_adapter/3` function, called with `:websocket` as the second
  argument. Applications should validate that the connection represents a valid WebSocket request
  before calling this function (Bandit will validate the connection as part of the upgrade
  process, but does not provide any capacity for an application to be notified if the upgrade is
  not successful). If an application wishes to negotiate WebSocket subprotocols or otherwise set
  any response headers, it should do so before calling `Plug.Conn.upgrade_adapter/3`.

  The third argument to `Plug.Conn.upgrade_adapter/3` defines the details of how Bandit should 
  handle the WebSocket connection, and must take the form `{handler, handler_opts,
  connection_opts}`, where values are as follows:

  * `handler` is a module which implements the `WebSock` API
  * `handler_opts` is an arbitrary term which will be passed as the argument to `c:WebSock.init/1`
  * `connection_opts` is a keyword list which consists of zero or more of the following options:
    * `timeout`: The number of milliseconds to wait after no client data is received before
      closing the connection. Defaults to `60_000`
    * `compress`: Whether or not to accept negotiation of a compression extension with the
      client. Defaults to `false`
    * `fullsweep_after`: The maximum number of garbage collections
      before forcing a full sweep of the socket process. You can set it to `0` to force more
      frequent cleanups of your websocket transport processes. Setting this option requires
      Erlang/OTP 24

  """

  require Logger

  @typedoc "A Plug definition"
  @type plug :: {module(), keyword()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: make_ref(), start: {__MODULE__, :start_link, [arg]}}
  end

  @doc """
  Starts a Bandit server using the provided arguments. See "Config Options' above for specific
  options to pass to this function.
  """
  def start_link(arg) do
    {options, illegal_options} =
      arg
      |> Keyword.get(:options, [])
      |> Keyword.split(~w(port num_acceptors read_timeout transport_module transport_options)a)

    if illegal_options != [] do
      raise "Unsupported option(s) in Bandit config: #{inspect(illegal_options)}"
    end

    scheme = Keyword.get(arg, :scheme, :http)
    {plug_mod, _} = plug = plug(arg)
    display_plug = Keyword.get(arg, :display_plug, plug_mod)

    {transport_module, extra_transport_options} =
      case scheme do
        :http -> {ThousandIsland.Transports.TCP, []}
        :https -> {ThousandIsland.Transports.SSL, alpn_preferred_protocols: ["h2", "http/1.1"]}
      end

    handler_options = %{plug: plug, handler_module: Bandit.InitialHandler}

    options
    |> Keyword.put_new(:read_timeout, 15_000)
    |> Keyword.put_new(:num_acceptors, 100)
    |> Keyword.put_new(:transport_module, transport_module)
    |> Keyword.update(
      :transport_options,
      extra_transport_options,
      &(&1 ++ extra_transport_options)
    )
    |> Keyword.put(:handler_module, Bandit.DelegatingHandler)
    |> Keyword.put(:handler_options, handler_options)
    |> ThousandIsland.start_link()
    |> case do
      {:ok, pid} ->
        Logger.info(info(scheme, display_plug, pid))
        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  defp plug(arg) do
    arg
    |> Keyword.get(:plug)
    |> case do
      nil -> {nil, nil}
      {plug, plug_options} -> {plug, plug.init(plug_options)}
      plug -> {plug, plug.init([])}
    end
  end

  defp info(scheme, plug, pid) do
    server_vsn = Application.spec(:bandit)[:vsn]
    "Running #{inspect(plug)} with Bandit #{server_vsn} at #{bound_address(scheme, pid)}"
  end

  defp bound_address(scheme, pid) do
    {:ok, %{address: address, port: port}} = ThousandIsland.listener_info(pid)

    case address do
      {:local, unix_path} ->
        "#{unix_path} (#{scheme}+unix)"

      address ->
        "#{:inet.ntoa(address)}:#{port} (#{scheme})"
    end
  end
end
