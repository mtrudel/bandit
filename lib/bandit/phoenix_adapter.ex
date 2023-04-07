defmodule Bandit.PhoenixAdapter do
  @moduledoc """
  A Bandit adapter for Phoenix.

  WebSocket support requires a version of Phoenix with Plug upgrade support, which is available
  as part of Phoenix 1.7 and later. This module will work fine on earlier versions of Phoenix,
  just without WebSocket support.

  To use this adapter, your project will need to include Bandit as a dependency; see
  https://hex.pm/bandit for details on the currently supported version of Bandit to include. Once
  Bandit is included as a dependency of your Phoenix project, add the following to your endpoint
  configuration in `config/config.exs`:

  ```
  config :your_app, YourAppWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter
  ```

  ## Endpoint configuration

  Configuring Bandit within your Phoenix app is done in largely the same way as configuration for
  Cowboy works. For the most part, your existing configuration within your `/config/*.exs` files
  will work unchanged, although some of the more exotic options are different. Bandit supports the
  following parameters within the `:http` and `:https` parameters:

    * `:http`: the configuration for the HTTP server. Accepts the following options:
      * `port`: The port to run on. Defaults to 4000. Note that if a Unix domain socket is
        specified in the `ip` option, the value of `port` **must** be `0`.
      * `ip`: The address to bind to. Can be specified as a 4-element tuple such as `{127, 0, 0, 1}`
        for IPv4 addresses, an 8-element tuple for IPv6 addresses, or using `{:local, path}` to bind
        to a Unix domain socket. Defaults to the Bandit default of `{0, 0, 0, 0, 0, 0, 0, 0}`.
      * `transport_options`: Any valid value from `ThousandIsland.Transports.TCP`
      * `http_1_options`: Any valid value from the `http_1_options` section of `Bandit`'s config documentation
      * `http_2_options`: Any valid value from the `http_2_options` section of `Bandit`'s config documentation
      * `websocket_options`: Any valid value from the `websocket_options` section of `Bandit`'s config documentation

      Defaults to `false`, which will cause Bandit to not start an HTTP server.

    * `:https`: the configuration for the HTTPS server. Accepts the following options:
      * `port`: The port to run on. Defaults to 4040. Note that if a Unix domain socket is
        specified in the `ip` option, the value of `port` **must** be `0`.
      * `ip`: The address to bind to. Can be specified as a 4-element tuple such as `{127, 0, 0, 1}`
        for IPv4 addresses, an 8-element tuple for IPv6 addresses, or using `{:local, path}` to bind
        to a Unix domain socket. Defaults to the Bandit default of `{0, 0, 0, 0, 0, 0, 0, 0}`.
      * `transport_options`: Any valid value from `ThousandIsland.Transports.SSL`
      * `http_1_options`: Any valid value from the `http_1_options` section of `Bandit`'s config documentation
      * `http_2_options`: Any valid value from the `http_2_options` section of `Bandit`'s config documentation
      * `websocket_options`: Any valid value from the `websocket_options` section of `Bandit`'s config documentation

      Defaults to `false`, which will cause Bandit to not start an HTTPS server.
  """

  @doc false
  def child_specs(endpoint, config) do
    for {scheme, default_port} <- [http: 4000, https: 4040], opts = config[scheme] do
      plug = resolve_plug(config[:code_reloader], endpoint)

      opts
      |> build_options(default_port)
      |> Keyword.merge(plug: plug, display_plug: endpoint, scheme: scheme)
      |> Bandit.child_spec()
      |> Supervisor.child_spec(id: {endpoint, scheme})
    end
  end

  defp resolve_plug(code_reload?, endpoint) do
    if code_reload? &&
         Code.ensure_loaded?(Phoenix.Endpoint.SyncCodeReloadPlug) &&
         function_exported?(Phoenix.Endpoint.SyncCodeReloadPlug, :call, 2) do
      {Phoenix.Endpoint.SyncCodeReloadPlug, {endpoint, []}}
    else
      endpoint
    end
  end

  defp build_options(opts, default_port) do
    {ip_options, options} = Keyword.split(opts, [:ip])
    {thousand_island_options, options} = Keyword.split(options, [:port, :transport_options])

    thousand_island_options =
      thousand_island_options
      |> Keyword.update!(:port, fn
        nil -> default_port
        port when is_binary(port) -> String.to_integer(port)
        port when is_integer(port) -> port
      end)
      |> Keyword.update(:transport_options, ip_options, &Keyword.merge(&1, ip_options))

    Keyword.put(options, :thousand_island_options, thousand_island_options)
  end
end
