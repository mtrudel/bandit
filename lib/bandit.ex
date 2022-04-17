defmodule Bandit do
  @moduledoc """
  Bandit is an HTTP server for Plug apps.

  As an HTTP server, Bandit's primary goal is to act as 'glue' between client connections managed
  by [Thousand Island](https://github.com/mtrudel/thousand_island) and application code defined
  via the [Plug API](https://github.com/elixir-plug/plug). As such there really isn't a whole lot
  of user-visible surface area to Bandit, and as a consequence the API documentation presented here
  is somewhat sparse. This is by design! Bandit is intended to 'just work' in almost all cases;
  the only thought users typically have to put into Bandit comes in the choice of which options (if
  any) they would like to change when starting a Bandit server. The sparseness of the Bandit API
  should not be taken as an indicator of the comprehensiveness or robustness of the project.

  ## Basic Usage

  Usage of Bandit is very straightforward. Assuming you have a Plug module implemented already, you can
  host it within Bandit by adding something similar to the following to your application's
  `Application.start/2` function:

  ```elixir
  def start(_type, _args) do
    children = [
      {Bandit, plug: MyApp.MyPlug, scheme: :http, options: [port: 4000]}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  ## Writing Plug Applications

  For details about writing Plug based applications, consult the excellent [Plug
  documentation](https://hexdocs.pm/plug/) for plenty of examples & tips to get started. Note that
  while Bandit supports the complete Plug API & should work correctly with any Plug-based
  application you may write, it does not currently support Phoenix applications due to our lack of
  support for WebSocket connections. Early support for Phoenix will be coming to Bandit in the
  0.4.x release series (likely Q4'21), with full support landing in the 0.7.x release series
  (likely Q1'22).

  ## Config Options

  Bandit takes a number of options at startup:

  * `plug`: The plug to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `scheme`: One of `:http` or `:https`. If `:https` is specified, you will need
     to specify `certfile` and `keyfile` in the `transport_options` subsection of `options`.
  * `read_timeout`: How long to wait for data from the client before timing out and closing the
    connection, specified in milliseconds. Defaults to 60_000
  * `options`: Options to pass to `ThousandIsland`. For an exhaustive list of options see the 
    `ThousandIsland` documentation, however some common options are:
      * `port`: The port to bind to. Defaults to 4000
      * `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
      tuning knob and can usually be left at the default value of 10
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
  """

  require Logger

  @typedoc "A Plug definition"
  @type plug :: {module(), keyword()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: Bandit, start: {__MODULE__, :start_link, [arg]}}
  end

  @doc """
  Starts a Bandit server using the provided arguments. See "Config Options' above for specific
  options to pass to this function.
  """
  def start_link(arg) do
    {options, illegal_options} =
      arg
      |> Keyword.get(:options, [])
      |> Keyword.split(~w(port num_acceptors transport_module transport_options)a)

    if illegal_options != [] do
      raise "Unsupported option(s) in Bandit config: #{inspect(illegal_options)}"
    end

    scheme = Keyword.get(arg, :scheme, :http)
    {plug_mod, _} = plug = plug(arg)

    {transport_module, extra_transport_options} =
      case scheme do
        :http -> {ThousandIsland.Transports.TCP, []}
        :https -> {ThousandIsland.Transports.SSL, alpn_preferred_protocols: ["h2", "http/1.1"]}
      end

    handler_options = %{
      plug: plug,
      handler_module: Bandit.InitialHandler,
      read_timeout: Keyword.get(arg, :read_timeout, 60_000)
    }

    options
    |> Keyword.put_new(:transport_module, transport_module)
    |> Keyword.update(
      :transport_options,
      extra_transport_options,
      &Keyword.merge(&1, extra_transport_options)
    )
    |> Keyword.put(:handler_module, Bandit.DelegatingHandler)
    |> Keyword.put(:handler_options, handler_options)
    |> ThousandIsland.start_link()
    |> case do
      {:ok, pid} ->
        Logger.info(info(scheme, plug_mod, pid))
        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  defp plug(arg) do
    arg
    |> Keyword.fetch!(:plug)
    |> case do
      {plug, plug_options} -> {plug, plug.init(plug_options)}
      plug -> {plug, plug.init([])}
    end
  end

  defp info(scheme, plug, pid) do
    server = "Bandit #{Application.spec(:bandit)[:vsn]}"
    "Running #{inspect(plug)} with #{server} at #{bound_address(scheme, pid)}"
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
