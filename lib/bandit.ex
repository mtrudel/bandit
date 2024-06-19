defmodule Bandit do
  @external_resource Path.join([__DIR__, "../README.md"])

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

  #{@external_resource |> File.read!() |> String.split("<!-- MDOC -->") |> Enum.fetch!(1)}
  """

  @typedoc """
  Possible top-level options to configure a Bandit server

  * `plug`: The Plug to use to handle connections. Can be specified as `MyPlug` or `{MyPlug, plug_opts}`
  * `scheme`: One of `:http` or `:https`. If `:https` is specified, you will also need to specify
    valid `certfile` and `keyfile` values (or an equivalent value within
    `thousand_island_options.transport_options`). Defaults to `:http`
  * `port`: The TCP port to listen on. This option is offered as a convenience and actually sets
    the option of the same name within `thousand_island_options`. If a string value is passed, it
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
  * `inet`: Only bind to IPv4 interfaces. This option is offered as a convenience and actually sets the
    option of the same name within `thousand_island_options.transport_options`. Must be specified
    as a bare atom `:inet`
  * `inet6`: Only bind to IPv6 interfaces. This option is offered as a convenience and actually sets the
    option of the same name within `thousand_island_options.transport_options`. Must be specified
    as a bare atom `:inet6`
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
  * `http_options`: A list of options to configure the shared aspects of Bandit's HTTP stack. A
    complete list can be found at `t:http_options/0`
  * `http_1_options`: A list of options to configure Bandit's HTTP/1 stack. A complete list can
    be found at `t:http_1_options/0`
  * `http_2_options`: A list of options to configure Bandit's HTTP/2 stack. A complete list can
    be found at `t:http_2_options/0`
  * `websocket_options`: A list of options to configure Bandit's WebSocket stack. A complete list can
    be found at `t:websocket_options/0`
  """
  @type options :: [
          {:plug, module() | {module(), Plug.opts()}}
          | {:scheme, :http | :https}
          | {:port, :inet.port_number()}
          | {:ip, :inet.socket_address()}
          | :inet
          | :inet6
          | {:keyfile, binary()}
          | {:certfile, binary()}
          | {:otp_app, Application.app()}
          | {:cipher_suite, :strong | :compatible}
          | {:display_plug, module()}
          | {:startup_log, Logger.level() | false}
          | {:thousand_island_options, ThousandIsland.options()}
          | {:http_options, http_options()}
          | {:http_1_options, http_1_options()}
          | {:http_2_options, http_2_options()}
          | {:websocket_options, websocket_options()}
        ]

  @typedoc """
  Options to configure shared aspects of the HTTP stack in Bandit

  * `compress`: Whether or not to attempt compression of responses via content-encoding
    negotiation as described in
    [RFC9110§8.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.4). Defaults to true
  * `deflate_options`: A keyword list of options to set on the deflate library. A complete list can
    be found at `t:deflate_options/0`. Note that these options only affect the behaviour of the
    'deflate' content encoding; 'gzip' does not have any configurable options (this is a
    limitation of the underlying `:zlib` library)
  * `log_exceptions_with_status_codes`: Which exceptions to log. Bandit will log only those
    exceptions whose status codes (as determined by `Plug.Exception.status/1`) match the specified
    list or range. Defaults to `500..599`
  * `log_protocol_errors`: How to log protocol errors such as malformed requests. `:short` will
    log a single-line summary, while `:verbose` will log full stack traces. The value of `false`
    will disable protocol error logging entirely. Defaults to `:short`
  """
  @type http_options :: [
          {:compress, boolean()}
          | {:deflate_opions, deflate_options()}
          | {:log_exceptions_with_status_codes, list() | Range.t()}
          | {:log_protocol_errors, :short | :verbose | false}
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
  * `clear_process_dict`: Whether to clear the process dictionary of all non-internal entries
    between subsequent keepalive requests. If set, all keys not starting with `$` are removed from
    the process dictionary between requests. Defaults to `true`
  * `gc_every_n_keepalive_requests`: How often to run a full garbage collection pass between subsequent
    keepalive requests on the same HTTP/1.1 connection. Defaults to 5 (garbage collect between
    every 5 requests). This option is currently experimental, and may change at any time
  * `log_unknown_messages`: Whether or not to log unknown messages sent to the handler process.
    Defaults to `false`
  """
  @type http_1_options :: [
          {:enabled, boolean()}
          | {:max_request_line_length, pos_integer()}
          | {:max_header_length, pos_integer()}
          | {:max_header_count, pos_integer()}
          | {:max_requests, pos_integer()}
          | {:clear_process_dict, boolean()}
          | {:gc_every_n_keepalive_requests, pos_integer()}
          | {:log_unknown_messages, boolean()}
        ]

  @typedoc """
  Options to configure the HTTP/2 stack in Bandit

  * `enabled`: Whether or not to serve HTTP/2 requests. Defaults to true
  * `max_header_block_size`: The maximum permitted length of a field block of an HTTP/2 request
    (expressed as the number of compressed bytes). Includes any concatenated block fragments from
    continuation frames. Defaults to 50_000 bytes
  * `max_requests`: The maximum number of requests to serve in a single
    HTTP/2 connection before closing the connection. Defaults to 0 (no limit)
  * `default_local_settings`: Options to override the default values for local HTTP/2
    settings. Values provided here will override the defaults specified in RFC9113§6.5.2
  """
  @type http_2_options :: [
          {:enabled, boolean()}
          | {:max_header_block_size, pos_integer()}
          | {:max_requests, pos_integer()}
          | {:default_local_settings, Bandit.HTTP2.Settings.t()}
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
          {:enabled, boolean()}
          | {:max_frame_size, pos_integer()}
          | {:validate_text_frames, boolean()}
          | {:compress, boolean()}
        ]

  @typedoc """
  Options to configure the deflate library used for HTTP compression
  """
  @type deflate_options :: [
          {:level, :zlib.zlevel()}
          | {:window_bits, :zlib.zwindowbits()}
          | {:memory_level, :zlib.zmemlevel()}
          | {:strategy, :zlib.zstrategy()}
        ]

  @typep scheme :: :http | :https

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

  @top_level_keys ~w(plug scheme port ip keyfile certfile otp_app cipher_suite display_plug startup_log thousand_island_options http_options http_1_options http_2_options websocket_options)a
  @http_keys ~w(compress deflate_options log_exceptions_with_status_codes log_protocol_errors)a
  @http_1_keys ~w(enabled max_request_line_length max_header_length max_header_count max_requests clear_process_dict gc_every_n_keepalive_requests log_unknown_messages)a
  @http_2_keys ~w(enabled max_header_block_size max_requests default_local_settings)a
  @websocket_keys ~w(enabled max_frame_size validate_text_frames compress)a
  @thousand_island_keys ThousandIsland.ServerConfig.__struct__()
                        |> Map.from_struct()
                        |> Map.keys()

  @doc """
  Starts a Bandit server using the provided arguments. See `t:options/0` for specific options to
  pass to this function.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(arg) do
    # Special case top-level `:inet` and `:inet6` options so we can use keyword logic everywhere else
    arg = arg |> special_case_inet_options() |> validate_options(@top_level_keys, "top level")

    thousand_island_options =
      Keyword.get(arg, :thousand_island_options, [])
      |> validate_options(@thousand_island_keys, :thousand_island_options)

    http_options =
      Keyword.get(arg, :http_options, [])
      |> validate_options(@http_keys, :http_options)

    http_1_options =
      Keyword.get(arg, :http_1_options, [])
      |> validate_options(@http_1_keys, :http_1_options)

    http_2_options =
      Keyword.get(arg, :http_2_options, [])
      |> validate_options(@http_2_keys, :http_2_options)

    websocket_options =
      Keyword.get(arg, :websocket_options, [])
      |> validate_options(@websocket_keys, :websocket_options)

    {plug_mod, _} = plug = plug(arg)
    display_plug = Keyword.get(arg, :display_plug, plug_mod)
    startup_log = Keyword.get(arg, :startup_log, :info)

    {http_1_enabled, http_1_options} = Keyword.pop(http_1_options, :enabled, true)
    {http_2_enabled, http_2_options} = Keyword.pop(http_2_options, :enabled, true)

    handler_options = %{
      plug: plug,
      handler_module: Bandit.InitialHandler,
      opts: %{
        http: http_options,
        http_1: http_1_options,
        http_2: http_2_options,
        websocket: websocket_options
      },
      http_1_enabled: http_1_enabled,
      http_2_enabled: http_2_enabled
    }

    scheme = Keyword.get(arg, :scheme, :http)

    {transport_module, transport_options, default_port} =
      case scheme do
        :http ->
          transport_options =
            Keyword.take(arg, [:ip])
            |> then(&(Keyword.get(thousand_island_options, :transport_options, []) ++ &1))

          {ThousandIsland.Transports.TCP, transport_options, 4000}

        :https ->
          supported_protocols =
            if(http_2_enabled, do: ["h2"], else: []) ++
              if http_1_enabled, do: ["http/1.1"], else: []

          transport_options =
            Keyword.take(arg, [:ip, :keyfile, :certfile, :otp_app, :cipher_suite])
            |> Keyword.merge(alpn_preferred_protocols: supported_protocols)
            |> then(&(Keyword.get(thousand_island_options, :transport_options, []) ++ &1))
            |> Plug.SSL.configure()
            |> case do
              {:ok, options} -> options
              {:error, message} -> raise "Plug.SSL.configure/1 encountered error: #{message}"
            end
            |> Enum.reject(&(is_tuple(&1) and elem(&1, 0) == :otp_app))

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
        startup_log && Logger.log(startup_log, info(scheme, display_plug, pid), domain: [:bandit])
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} = error ->
        Logger.error([info(scheme, display_plug, nil), " failed, port #{port} already in use"],
          domain: [:bandit]
        )

        error

      {:error, _} = error ->
        error
    end
  end

  @spec special_case_inet_options(options()) :: options()
  defp special_case_inet_options(opts) do
    {inet_opts, opts} = Enum.split_with(opts, &(&1 in [:inet, :inet6]))

    if inet_opts == [] do
      opts
    else
      Keyword.update(
        opts,
        :thousand_island_options,
        [transport_options: inet_opts],
        fn thousand_island_opts ->
          Keyword.update(thousand_island_opts, :transport_options, inet_opts, &(&1 ++ inet_opts))
        end
      )
    end
  end

  @spec validate_options(Keyword.t(), [atom(), ...], String.t() | atom()) ::
          Keyword.t() | no_return()
  defp validate_options(options, valid_values, name) do
    case Keyword.split(options, valid_values) do
      {options, []} ->
        options

      {_, illegal_options} ->
        raise "Unsupported key(s) in #{name} config: #{inspect(Keyword.keys(illegal_options))}"
    end
  end

  @spec plug(options()) :: {module(), Plug.opts()}
  defp plug(arg) do
    arg
    |> Keyword.get(:plug)
    |> case do
      nil -> raise "A value is required for :plug"
      {plug_fn, plug_options} when is_function(plug_fn, 2) -> {plug_fn, plug_options}
      plug_fn when is_function(plug_fn) -> {plug_fn, []}
      {plug, plug_options} when is_atom(plug) -> validate_plug(plug, plug_options)
      plug when is_atom(plug) -> validate_plug(plug, [])
      other -> raise "Invalid value for plug: #{inspect(other)}"
    end
  end

  defp validate_plug(plug, plug_options) do
    Code.ensure_loaded!(plug)
    if !function_exported?(plug, :init, 1), do: raise("plug module does not define init/1")
    if !function_exported?(plug, :call, 2), do: raise("plug module does not define call/2")

    {plug, plug.init(plug_options)}
  end

  @spec parse_as_number(binary() | integer()) :: integer()
  defp parse_as_number(value) when is_binary(value), do: String.to_integer(value)
  defp parse_as_number(value) when is_integer(value), do: value

  @spec info(scheme(), module(), nil | pid()) :: String.t()
  defp info(scheme, plug, pid) do
    server_vsn = Application.spec(:bandit)[:vsn]
    "Running #{inspect(plug)} with Bandit #{server_vsn} at #{bound_address(scheme, pid)}"
  end

  @spec bound_address(scheme(), nil | pid()) :: String.t() | scheme()
  defp bound_address(scheme, nil), do: scheme

  defp bound_address(scheme, pid) do
    {:ok, {address, port}} = ThousandIsland.listener_info(pid)

    case address do
      :local -> "#{_unix_path = port} (#{scheme}+unix)"
      :undefined -> "#{inspect(port)} (#{scheme}+undefined)"
      :unspec -> "unspec (#{scheme})"
      address -> "#{:inet.ntoa(address)}:#{port} (#{scheme})"
    end
  end
end
