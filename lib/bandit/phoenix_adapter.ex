defmodule Bandit.PhoenixAdapter do
  @moduledoc """
  A Bandit adapter for Phoenix.

  WebSocket support requires a version of Phoenix with Plug upgrade & Sock support. This is
  currently (Sept 2022) a work in progress. This module will work fine on earlier versions of
  Phoenix, just without WebSocket support.

  To use this adapter, your project will need to include Bandit as a dependency; see
  https://hex.pm/bandit for details on the currently supported version of Bandit to include. Once
  Bandit is included as a dependency of your Phoenix project, add the following to your endpoint
  configuration in `config/config.exs`:

  ```
  config :your_app, YourAppWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter
  ```

  ## Endpoint configuration

  This adapter uses the following endpoint configuration:

    * `:http`: the configuration for the HTTP server. Accepts the following options:
      * `port`: The port to run on. Defaults to 4000
      * `ip`: The address to bind to. Can be specified as `{127, 0, 0, 1}`, or using `{:local,
        path}` to bind to a Unix domain socket. Defaults to {127, 0, 0, 1}.
      * `transport_options`: Any valid value from `ThousandIsland.Transports.TCP`
    
      Defaults to `false`, which will cause Bandit to not start an HTTP server.

    * `:https`: the configuration for the HTTPS server. Accepts the following options:
      * `port`: The port to run on. Defaults to 4040
      * `ip`: The address to bind to. Can be specified as `{127, 0, 0, 1}`, or using `{:local,
        path}` to bind to a Unix domain socket. Defaults to {127, 0, 0, 1}.
      * `transport_options`: Any valid value from `ThousandIsland.Transports.SSL`
    
      Defaults to `false`, which will cause Bandit to not start an HTTPS server.
  """

  require Logger

  @doc false
  def child_specs(endpoint, config) do
    for {scheme, default_port} <- [http: 4000, https: 4040], opts = config[scheme] do
      port = Keyword.get(opts, :port, default_port)
      ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
      transport_options = Keyword.get(opts, :transport_options, [])
      opts = [port: port_to_integer(port), transport_options: [ip: ip] ++ transport_options]

      [plug: endpoint, scheme: scheme, options: opts]
      |> Bandit.child_spec()
      |> Supervisor.child_spec(id: {endpoint, scheme})
    end
  end

  defp port_to_integer(port) when is_binary(port), do: String.to_integer(port)
  defp(port_to_integer(port) when is_integer(port), do: port)
end
