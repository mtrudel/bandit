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

      Defaults to `false`, which will cause Bandit to not start an HTTP server.

    * `:https`: the configuration for the HTTPS server. Accepts the following options:
      * `port`: The port to run on. Defaults to 4040. Note that if a Unix domain socket is
        specified in the `ip` option, the value of `port` **must** be `0`.
      * `ip`: The address to bind to. Can be specified as a 4-element tuple such as `{127, 0, 0, 1}`
        for IPv4 addresses, an 8-element tuple for IPv6 addresses, or using `{:local, path}` to bind
        to a Unix domain socket. Defaults to the Bandit default of `{0, 0, 0, 0, 0, 0, 0, 0}`.
      * `transport_options`: Any valid value from `ThousandIsland.Transports.SSL`

      Defaults to `false`, which will cause Bandit to not start an HTTPS server.
  """

  require Logger

  @doc false
  def child_specs(endpoint, config) do
    for {scheme, default_port} <- [http: 4000, https: 4040], opts = config[scheme] do
      port = Keyword.get(opts, :port, default_port)
      ip_opt = Keyword.take(opts, [:ip])
      transport_options = Keyword.get(opts, :transport_options, [])
      opts = [port: port_to_integer(port), transport_options: ip_opt ++ transport_options]

      plug =
        if config[:code_reloader] &&
             Code.ensure_loaded?(Phoenix.Endpoint.SyncCodeReloadPlug) &&
             function_exported?(Phoenix.Endpoint.SyncCodeReloadPlug, :call, 2) do
          {Phoenix.Endpoint.SyncCodeReloadPlug, {endpoint, []}}
        else
          endpoint
        end

      [plug: plug, display_plug: endpoint, scheme: scheme, options: opts]
      |> Bandit.child_spec()
      |> Supervisor.child_spec(id: {endpoint, scheme})
    end
  end

  defp port_to_integer(port) when is_binary(port), do: String.to_integer(port)
  defp port_to_integer(port) when is_integer(port), do: port
end
