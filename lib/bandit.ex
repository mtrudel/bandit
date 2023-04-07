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
    {:bandit, ">= 0.7.0"}
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
     Defaults to `:http`
  * `:startup_log` - The log level at which Bandit should log startup info.
    Defaults to `:info` log level, can be set to false to disable it.
  * `options`: Options to pass to `ThousandIsland`. For an exhaustive list of options see the
    `ThousandIsland` documentation, however some common options are:
      * `port`: The port to bind to. Defaults to 4000
      * `num_acceptors`: The number of acceptor processes to run. This is mostly a performance
      tuning knob and can usually be left at the default value of 100
      * `read_timeout`: How long to wait for data from the client before timing out and closing the
      connection, specified in milliseconds. Defaults to `60_000` milliseconds
      * `shutdown_timeout`: How long to wait for existing connections to complete before forcibly
      shutting them down at server shutdown, specified in milliseconds. Defaults to `15_000`
      milliseconds. May also be `:infinity` or `:brutal_kill` as described in the `Supervisor`
      documentation.
      * `transport_options`: A keyword list of options to be passed into the transport socket's listen function
      * `transport_module`: The name of the module which provides basic socket functions.
      This overrides any value set for `scheme` and is intended for cases where control
      over the socket at a fundamental level is needed. You almost certainly don't want to fuss
      with this option unless you know exactly what you're doing
      * `handler_module`: The name of the module which Thousand Island will use to handle
      requests. This overrides Bandit's built in handler and is intended for cases where control
      over requests at a fundamental level is needed. You almost certainly don't want to fuss
      with this option unless you know exactly what you're doing
  * `http_1_options`: Options to configure the HTTP/1 stack in Bandit. Valid options are:
      * `enabled`: Whether or not to serve HTTP/1 requests. Defaults to true
      * `max_request_line_length`: The maximum permitted length of the request line
      (expressed as the number of bytes on the wire) in an HTTP/1.1 request. Defaults to 10_000 bytes
      * `max_header_length`: The maximum permitted length of any single header (combined
      key & value, expressed as the number of bytes on the wire) in an HTTP/1.1 request. Defaults to 10_000 bytes
      * `max_header_count`: The maximum permitted number of headers in an HTTP/1.1 request.
      Defaults to 50 headers
      * `max_requests`: The maximum number of requests to serve in a single
      HTTP/1.1 connection before closing the connection. Defaults to 0 (no limit)
      * `compress`: Whether or not to attempt compression of responses via content-encoding
      negotiation as described in
      [RFC9110§8.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.4). Defaults to true
      * `deflate_opts`: A keyword list of options to set on the deflate library. Possible options
      are:
        * `level`: The compression level to use for deflation. May be one of `none`, `default`,
        `best_compression`, `best_speed`, or an integer in `0..9`. See [:zlib
        documentation](https://www.erlang.org/doc/man/zlib.html#type-zlevel) for more information.
        Defaults to `default`
        * `window_bits`: The base-2 log of the size of the histroy buffer. Largers values compress
        better, but use more memory. Defaults to 15
        * `memory_level`: The memory level to use for deflation. May be an integer in `1..9`. See
        [:zlib documentation](https://www.erlang.org/doc/man/zlib.html#type-zmemlevel) for more
        information. Defaults to `8`
        * `strategy`: The strategy to use for deflation. May be one of `default`, `filtered`,
        `huffman_only`, or `rle`. See [:zlib
        documentation](https://www.erlang.org/doc/man/zlib.html#type-zstrategy) for more
        information. Defaults to `default`
  * `http_2_options`: Options to configure the HTTP/2 stack in Bandit. Valid options are:
      * `enabled`: Whether or not to serve HTTP/2 requests. Defaults to true
      * `max_header_key_length`: The maximum permitted length of any single header key
      (expressed as the number of decompressed bytes) in an HTTP/2 request. Defaults to 10_000 bytes
      * `max_header_value_length`: The maximum permitted length of any single header value
      (expressed as the number of decompressed bytes) in an HTTP/2 request. Defaults to 10_000 bytes
      * `max_header_count`: The maximum permitted number of headers in an HTTP/2 request.
      Defaults to 50 headers
      * `max_requests`: The maximum number of requests to serve in a single
      HTTP/2 connection before closing the connection. Defaults to 0 (no limit)
      * `default_local_settings`: Options to override the default values for local HTTP/2
      settings. Values provided here will override the defaults specified in RFC9113§6.5.2.
      * `compress`: Whether or not to attempt compression of responses via content-encoding
      negotiation as described in
      [RFC9110§8.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.4). Defaults to true
      * `deflate_opts`: A keyword list of options to set on the deflate library. Possible options
      are the same as the `deflate_opts` option under the `http_1_options` section above
  * `websocket_options`: Options to configure the WebSocket stack in Bandit. Valid options are:
      * `enabled`: Whether or not to serve WebSocket upgrade requests. Defaults to true
      * `max_frame_size`: The maximum size of a single WebSocket frame (expressed as
      a number of bytes on the wire). Defaults to 0 (no limit)
      * `validate_text_frames`: Whether or not to validate text frames as being UTF-8. Strictly
      speaking this is required per RFC6455§5.6, however it can be an expensive operation and one
      that may be safely skipped in some situations. Defaults to true
      * `compress`: Whether or not to allow per-message deflate compression globally. Note that
      upgrade requests still need to set the `compress: true` option in `connection_opts` on
      a per-upgrade basis for compression to be negotiated (see 'WebSocket Support' section below
      for details). Defaults to `true`
      * `deflate_opts`: A keyword list of options to set on the deflate library. Possible options
      are the same as the `deflate_opts` option under the `http_1_options` section above, with the
      exception that the `window_bits` parameter is not available

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

  Bandit supports WebSocket implementations via the
  [WebSock](https://hexdocs.pm/websock/WebSock.html) and
  [WebSockAdapter](https://hexdocs.pm/websock_adapter/WebSockAdapter.html) libraries, which
  provide a generic abstraction for WebSockets (very similar to how Plug is a generic abstraction
  on top of HTTP). Bandit fully supports all aspects of these libraries.

  Applications should validate that the connection represents a valid WebSocket request
  before attempting an upgrade (Bandit will validate the connection as part of the upgrade
  process, but does not provide any capacity for an application to be notified if the upgrade is
  not successful). If an application wishes to negotiate WebSocket subprotocols or otherwise set
  any response headers, it should do so before upgrading.
  """

  require Logger

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [arg]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a Bandit server using the provided arguments. See "Config Options' above for specific
  options to pass to this function.
  """
  def start_link(arg) do
    arg =
      arg
      |> validate_options(
        ~w(scheme plug display_plug options http_1_options http_2_options websocket_options startup_log)a,
        "top level"
      )

    options =
      arg
      |> Keyword.get(:options, [])
      |> validate_options(
        ~w(port num_acceptors read_timeout shutdown_timeout transport_module transport_options handler_module)a,
        :options
      )

    http_1_options =
      arg
      |> Keyword.get(:http_1_options, [])
      |> validate_options(
        ~w(enabled max_request_line_length max_header_length max_header_count max_requests compress deflate_opts)a,
        :http_1_options
      )

    http_2_options =
      arg
      |> Keyword.get(:http_2_options, [])
      |> validate_options(
        ~w(enabled max_header_key_length max_header_value_length max_header_count max_requests default_local_settings compress deflate_opts)a,
        :http_2_options
      )

    websocket_options =
      arg
      |> Keyword.get(:websocket_options, [])
      |> validate_options(
        ~w(enabled max_frame_size validate_text_frames compress)a,
        :websocket_options
      )

    {plug_mod, _} = plug = plug(arg)
    display_plug = Keyword.get(arg, :display_plug, plug_mod)
    startup_log = Keyword.get(arg, :startup_log, :info)

    handler_options = %{
      plug: plug,
      handler_module: Bandit.InitialHandler,
      opts: %{http_1: http_1_options, http_2: http_2_options, websocket: websocket_options}
    }

    scheme = Keyword.get(arg, :scheme, :http)

    {transport_module, more_transport_options} =
      case scheme do
        :http -> {ThousandIsland.Transports.TCP, []}
        :https -> {ThousandIsland.Transports.SSL, alpn_preferred_protocols: ["h2", "http/1.1"]}
      end

    options
    |> Keyword.put_new(:transport_module, transport_module)
    |> Keyword.update(:transport_options, more_transport_options, &(&1 ++ more_transport_options))
    |> Keyword.put_new(:handler_module, Bandit.DelegatingHandler)
    |> Keyword.put(:handler_options, handler_options)
    |> ThousandIsland.start_link()
    |> case do
      {:ok, pid} ->
        startup_log && Logger.log(startup_log, info(scheme, display_plug, pid))
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} = error ->
        Logger.error([info(scheme, display_plug, nil), " failed, port already in use"])
        error

      {:error, _} = error ->
        error
    end
  end

  defp validate_options(options, valid_values, name) do
    case Keyword.split(options, valid_values) do
      {options, []} ->
        options

      {_, illegal_options} ->
        raise "Unsupported keys(s) in #{name} config: #{inspect(Keyword.keys(illegal_options))}"
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

  defp bound_address(scheme, nil), do: scheme

  defp bound_address(scheme, pid) do
    {:ok, %{address: address, port: port}} = ThousandIsland.listener_info(pid)

    case address do
      {:local, unix_path} -> "#{unix_path} (#{scheme}+unix)"
      address -> "#{:inet.ntoa(address)}:#{port} (#{scheme})"
    end
  end
end
