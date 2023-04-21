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
      {:bandit, ">= 1.0-pre"}
      ```
  2. Add the following `adapter:` line to your endpoint configuration in `config/config.exs`:

       ```elixir
       config :your_app, YourAppWeb.Endpoint,
         adapter: Bandit.PhoenixAdapter
       ```
  3. That's it! You should now see messages at startup indicating that Phoenix is
     using Bandit to serve your endpoint, and everything should 'just work'. Note
     that if you have set any exotic configuration options within your endpoint,
     you may need to update that configuration to work with Bandit; see the
     `Bandit.PhoenixAdapter` documentation for more information.

  ## Using Bandit With Plug Applications

  Using Bandit to host your own Plug is very straightforward. Assuming you have a Plug module
  implemented already, you can host it within Bandit by adding something similar to the following
  to your application's `Application.start/2` function:

  ```elixir
  def start(_type, _args) do
    children = [
      {Bandit, plug: MyPlug}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  ```

  For details about writing Plug based applications, consult the excellent [Plug
  documentation](https://hexdocs.pm/plug/) for plenty of examples & tips to get started.
  Bandit supports the complete Plug API & should work correctly with any Plug-based
  application. If you encounter errors using Bandit your Plug app, please do get in touch by
  filing an issue on the Bandit [GitHub project](https://github.com/mtrudel/bandit) (especially if
  the error does not occur with another HTTP server such as Cowboy).

  ## Configuration

  A number of options are defined when starting a server. The complete list is
  defined by the `t:Bandit.options/0` type.

  ## Setting up an HTTPS Server

  By far the most common stumbling block encountered when setting up an HTTPS server involves
  configuring key and certificate data.  Bandit is comparatively easy to set up in this regard,
  with a working example looking similar to the following:

  ```elixir
  def start(_type, _args) do
    children = [
      {Bandit,
       plug: MyPlug,
       scheme: :https,
       certfile: "/absolute/path/to/cert.pem",
       keyfile: "/absolute/path/to/key.pem"
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

  @typedoc """
  Possible top-level options to configure a Bandit server

  * `plug`: The Plug to use to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `scheme`: One of `:http` or `:https`. If `:https` is specified, you will also need to specify
    valid `certfile` and `keyfile` values (or an equivalent value within
    `thousand_island_options.transport_options`). Defaults to `:http`
  * `port`: The TCP port to listen on. This option is offered as a convenience and actually sets
    the option of the same name within `thousand_island_options`. If ia string value is passed, it 
    will be parsed as an integer. Defaults to 4000 if `scheme` is `:http`, and 4040 if `scheme` is
    `:https`
  * `ip`:  The interface(s) to listen on. This option is offered as a convenience and actually sets the
    option of the same name within `thousand_island_options.transport_options`. Can be specified as:
      * `{1, 2, 3, 4}` for IPv4 addresses
      * `{1, 2, 3, 4, 5, 6, 7, 8}` for IPv6 addresses
      * `:loopback` for local loopback (ie: `127.0.0.1`)
      * `:any` for all interfaces (ie: `0.0.0.0`)
      * `{:local, "/path/to/socket"}` for a Unix domain socket. If this option is used, the `port`
        option *must* be set to `0`
  * `keyfile`: The path to a file containing the SSL key to use for this server. This option is
    offered as a convenience and actually sets the option of the same name within
    `thousand_island_options.transport_options`. If a relative path is used here, you will also
    need to set the `otp_app` parameter and ensure that the named file is part of your application
    build
  * `certfile`: The path to a file containing the SSL certificate to use for this server. This option is
    offered as a convenience and actually sets the option of the same name within
    `thousand_island_options.transport_options`. If a relative path is used here, you will also
    need to set the `otp_app` parameter and ensure that the named file is part of your application
    build
  * `otp_app`: Provided as a convenience when using relative paths for `keyfile` and `certfile`
  * `cipher_suite`: Used to define a pre-selected set of ciphers, as described by
    `Plug.SSL.configure/1`. Optional, can be either `:strong` or `:compatible`
  * `display_plug`: The plug to use when describing the connection in logs. Useful for situations
    such as Phoenix code reloading where you have a 'wrapper' plug but wish to refer to the
    connection by the endpoint name
  * `startup_log`: The log level at which Bandit should log startup info.
    Defaults to `:info` log level, can be set to false to disable it
  * `thousand_island_options`: A list of options to pass to Thousand Island. Bandit sets some
    default values in this list based on your top-level configuration; these values will be
    overridden by values appearing here. A complete list can be found at
    `t:ThousandIsland.options/0`
  * `http_1_options`: A list of options to configure Bandit's HTTP/1 stack. A complete list can
    be found at `t:http_1_options/0`
  * `http_2_options`: A list of options to configure Bandit's HTTP/2 stack. A complete list can
    be found at `t:http_2_options/0`
  * `websocket_options`: A list of options to configure Bandit's WebSocket stack. A complete list can
    be found at `t:websocket_options/0`
  """
  @type options :: [
          plug: module() | {module(), Plug.opts()},
          scheme: :http | :https,
          port: :inet.port_number(),
          ip: :inet.socket_address(),
          keyfile: binary(),
          certfile: binary(),
          otp_app: binary() | atom(),
          cipher_suite: :strong | :compatible,
          display_plug: module(),
          startup_log: Logger.level() | false,
          thousand_island_options: ThousandIsland.options(),
          http_1_options: http_1_options(),
          http_2_options: http_2_options(),
          websocket_options: websocket_options()
        ]

  @typedoc """
  Options to configure the HTTP/1 stack in Bandit

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
  * `deflate_options`: A keyword list of options to set on the deflate library. A complete list can
    be found at `t:deflate_options/0`
  """
  @type http_1_options :: [
          enabled: boolean(),
          max_request_line_length: pos_integer(),
          max_header_length: pos_integer(),
          max_header_count: pos_integer(),
          max_requests: pos_integer(),
          compress: boolean(),
          deflate_opions: deflate_options()
        ]

  @typedoc """
  Options to configure the HTTP/2 stack in Bandit

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
    settings. Values provided here will override the defaults specified in RFC9113§6.5.2
  * `compress`: Whether or not to attempt compression of responses via content-encoding
    negotiation as described in
    [RFC9110§8.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.4). Defaults to true
  * `deflate_options`: A keyword list of options to set on the deflate library. A complete list can
    be found at `t:deflate_options/0`
  """
  @type http_2_options :: [
          enabled: boolean(),
          max_header_key_length: pos_integer(),
          max_header_value_length: pos_integer(),
          max_header_count: pos_integer(),
          max_requests: pos_integer(),
          default_local_settings: Bandit.HTTP2.Settings.t(),
          compress: boolean(),
          deflate_options: deflate_options()
        ]

  @typedoc """
  Options to configure the WebSocket stack in Bandit

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
  """
  @type websocket_options :: [
          enabled: boolean(),
          max_frame_size: pos_integer(),
          validate_text_frames: boolean(),
          compress: boolean()
        ]

  @typedoc """
  Options to configure the deflate library used for HTTP compression
  """
  @type deflate_options :: [
          level: :zlib.zlevel(),
          window_bits: :zlib.zwindowbits(),
          memory_level: :zlib.zmemlevel(),
          strategy: :zlib.zstrategy()
        ]

  require Logger

  @doc false
  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [arg]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a Bandit server using the provided arguments. See `t:options/0` for specific options to
  pass to this function.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(arg) do
    arg =
      arg
      |> validate_options(
        ~w(plug scheme port ip keyfile certfile otp_app cipher_suite display_plug startup_log thousand_island_options http_1_options http_2_options websocket_options)a,
        "top level"
      )

    thousand_island_options =
      arg
      |> Keyword.get(:thousand_island_options, [])
      |> validate_options(
        ThousandIsland.ServerConfig.__struct__() |> Map.from_struct() |> Map.keys(),
        :thousand_island_options
      )

    http_1_options =
      arg
      |> Keyword.get(:http_1_options, [])
      |> validate_options(
        ~w(enabled max_request_line_length max_header_length max_header_count max_requests compress deflate_options)a,
        :http_1_options
      )

    http_2_options =
      arg
      |> Keyword.get(:http_2_options, [])
      |> validate_options(
        ~w(enabled max_header_key_length max_header_value_length max_header_count max_requests default_local_settings compress deflate_options)a,
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

    {transport_module, transport_options, default_port} =
      case scheme do
        :http ->
          transport_options =
            Keyword.take(arg, [:ip])
            |> Keyword.merge(Keyword.get(thousand_island_options, :transport_options, []))

          {ThousandIsland.Transports.TCP, transport_options, 4000}

        :https ->
          transport_options =
            Keyword.take(arg, [:ip, :keyfile, :certfile, :otp_app, :cipher_suite])
            |> Keyword.merge(alpn_preferred_protocols: ["h2", "http/1.1"])
            |> Keyword.merge(Keyword.get(thousand_island_options, :transport_options, []))
            |> Plug.SSL.configure()
            |> case do
              {:ok, options} -> options
              {:error, message} -> raise "Plug.SSL.configure/1 encountered error: #{message}"
            end
            |> Keyword.delete(:otp_app)

          {ThousandIsland.Transports.SSL, transport_options, 4040}
      end

    port = Keyword.get(arg, :port, default_port) |> parse_as_number()

    thousand_island_options
    |> Keyword.put_new(:port, port)
    |> Keyword.put_new(:transport_module, transport_module)
    |> Keyword.put(:transport_options, transport_options)
    |> Keyword.put_new(:handler_module, Bandit.DelegatingHandler)
    |> Keyword.put_new(:handler_options, handler_options)
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
      nil -> raise "A value for is required for :plug"
      {plug, plug_options} -> {plug, plug.init(plug_options)}
      plug -> {plug, plug.init([])}
    end
  end

  defp parse_as_number(value) when is_binary(value), do: String.to_integer(value)
  defp parse_as_number(value) when is_integer(value), do: value

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
