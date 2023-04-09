defmodule Bandit.PhoenixAdapter do
  @moduledoc """
  A Bandit adapter for Phoenix.

  This adapter provides out-of-the-box support for all aspects of Phoenix 1.7 and later. Earlier
  versions of Phoenix will work with this adapter, but without support for WebSockets.

  To use this adapter, your project will need to include Bandit as a dependency:

  ```elixir
  {:bandit, ">= 0.7.6"}
  ```

  Once Bandit is included as a dependency of your Phoenix project, add the following `adapter:`
  line to your endpoint configuration in `config/config.exs`:

  ```
  config :your_app, YourAppWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter
  ```

  That's it! After restarting Phoenix you should see the startup message indicate that it is being
  served by Bandit, and everything should 'just work'. Note that if you have set any exotic
  configuration options within your endpoint, you may need to update that configuration to work
  with Bandit; see below for details.

  ## Endpoint configuration

  This adapter supports the standard Phoenix structure for endpoint configuration. Top-level keys for
  `:http` and `:https` are supported, and configuration values within each of those are interpreted
  as raw Bandit configuration as specified by `t:Bandit.options/0`. Bandit's confguration supports
  all values used in a standard out-of-the-box Phoenix application, so if you haven't made any
  substantial changes to your endpoint configuration things should 'just work' for you.

  In the event that you *have* made advanced changes to your endpoint configuration, you may need
  to update this config to work with Bandit. Consult Bandit's documentation at
  `t:Bandit.options/0` for details.
  """

  @doc false
  def child_specs(endpoint, config) do
    plug = resolve_plug(config[:code_reloader], endpoint)

    for scheme <- [:http, :https], opts = config[scheme] do
      opts
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
end
