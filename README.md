# Bandit

[![Build Status](https://github.com/mtrudel/bandit/workflows/Elixir%20CI/badge.svg)](https://github.com/mtrudel/bandit/actions)
[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/bandit)
[![Hex.pm](https://img.shields.io/hexpm/v/bandit.svg?style=flat&color=blue)](https://hex.pm/packages/bandit)

Bandit is an HTTP server for Plug and WebSock apps.

Bandit is written entirely in Elixir and is built atop [Thousand
Island](https://github.com/mtrudel/thousand_island). It can serve HTTP/1.x,
HTTP/2 and WebSocket clients over both HTTP and HTTPS. It is written with
correctness, clarity & performance as fundamental goals.

In [ongoing automated performance
tests](https://github.com/mtrudel/bandit/actions/runs/4449308920),
Bandit's HTTP/1.x engine is up to 4x faster than Cowboy depending on the number of concurrent
requests. When comparing HTTP/2 performance, Bandit is up to 1.5x faster than Cowboy. This is
possible because Bandit has been built from the ground up for use with Plug applications; this
focus pays dividends in both performance and also in the approachability of the code base.

Bandit also emphasizes correctness. Its HTTP/2 implementation scores 100% on the
[h2spec](https://github.com/summerwind/h2spec) suite in strict mode, and its
WebSocket implementation scores 100% on the
[Autobahn](https://github.com/crossbario/autobahn-testsuite) test suite, both of
which run as part of Bandit's comprehensive CI suite. Extensive unit test,
credo, dialyzer, and performance regression test coverage round out a test suite
that ensures that Bandit is and will remain a platform you can count on.

Lastly, Bandit exists to demystify the lower layers of infrastructure code. In a world where
The New Thing is nearly always adding abstraction on top of abstraction, it's important to have
foundational work that is approachable & understandable by users above it in the stack.

## Project Goals

* Implement comprehensive support for HTTP/1.0 through HTTP/2 & WebSockets (and
  beyond) backed by obsessive RFC literacy and automated conformance testing
* Aim for minimal internal policy and HTTP-level configuration. Delegate to Plug & WebSock as much as
  possible, and only interpret requests to the extent necessary to safely manage a connection
  & fulfill the requirements of safely supporting protocol correctness
* Prioritize (in order): correctness, clarity, performance. Seek to remove the mystery of
  infrastructure code by being approachable and easy to understand
* Along with our companion library [Thousand
  Island](https://github.com/mtrudel/thousand_island), become the go-to HTTP
  & low-level networking stack of choice for the Elixir community by being
  reliable, efficient, and approachable

## Project Status

* Complete support for [Phoenix](https://github.com/phoenixframework/phoenix) applications (WebSocket
  support requires Phoenix 1.7+)
* Complete support of the [Plug API](https://github.com/elixir-plug/plug)
* Complete support of the [WebSock API](https://github.com/phoenixframework/websock)
* Complete server support for HTTP/1.x as defined in [RFC
  9112](https://datatracker.ietf.org/doc/html/rfc9112) & [RFC
  9110](https://datatracker.ietf.org/doc/html/rfc9110)
* Complete server support for HTTP/2 as defined in [RFC
  9113](https://datatracker.ietf.org/doc/html/rfc9113) & [RFC
  9110](https://datatracker.ietf.org/doc/html/rfc9110), comprehensively covered
  by automated [h2spec](https://github.com/summerwind/h2spec) conformance
  testing
* Complete server support for WebSockets as defined in [RFC
  6455](https://datatracker.ietf.org/doc/html/rfc6455), comprehensively covered by automated
  [Autobahn](https://github.com/crossbario/autobahn-testsuite) conformance testing. Per-message
  compression as defined in [RFC 7692](https://datatracker.ietf.org/doc/html/rfc7692) is also
  supported
* Extremely scalable and performant client handling at a rate up to 4x that of Cowboy for the same
  workload with as-good-or-better memory use

Any Phoenix or Plug app should work with Bandit as a drop-in replacement for
Cowboy; exceptions to this are errors (if you find one, please [file an
issue!](https://github.com/mtrudel/bandit/issues)).

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
[Bandit.PhoenixAdapter](https://hexdocs.pm/bandit/Bandit.PhoenixAdapter.html) documentation.

## Using Bandit With Plug Applications

Using Bandit to host your own Plug is very straightforward. Assuming you have a Plug module
implemented already, you can host it within Bandit by adding something similar to the following
to your application's `Application.start/2` function:

```elixir
def start(_type, _args) do
  children = [
    {Bandit, plug: MyApp.MyPlug}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

Bandit takes a number of options at startup, which are described in detail in the Bandit
[documentation](https://hexdocs.pm/bandit/Bandit.html).

For less formal usage, you can also start Bandit using the same configuration
options via the `Bandit.start_link/1` function:

```elixir
# Start an http server on the default port 4000, serving MyApp.MyPlug
Bandit.start_link(plug: MyPlug)
```

## WebSocket Support

If you're using Bandit to run a Phoenix application as suggested above, there is
nothing more for you to do; WebSocket support will 'just work'.

If you wish to interact with WebSockets at a more fundamental level, the
[WebSock](https://hexdocs.pm/websock/WebSock.html) and
[WebSockAdapter](https://hexdocs.pm/websock_adapter/WebSockAdapter.html) libraries
provides a generic abstraction for WebSockets (very similar to how Plug is
a generic abstraction on top of HTTP). Bandit fully supports all aspects of
these libraries. 

## Implementation Details

Bandit's HTTP/2 implementation is described in detail in its own
[README](lib/bandit/http2/README.md). Similar documentation for the HTTP/1.x and
WebSocket implementations is a work in progress.

## Contributing

Contributions to Bandit are very much welcome! Before undertaking any substantial work, please
open an issue on the project to discuss ideas and planned approaches so we can ensure we keep
progress moving in the same direction.

All contributors must agree and adhere to the project's [Code of
Conduct](https://github.com/mtrudel/bandit/blob/main/CODE_OF_CONDUCT.md).

Security disclosures should be handled per Bandit's published [security policy](https://github.com/mtrudel/bandit/blob/main/SECURITY.md).

## Installation

Bandit is [available in Hex](https://hex.pm/docs/publish). The package can be installed
by adding `bandit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bandit, ">= 0.7.0"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/bandit](https://hexdocs.pm/bandit).

# License

MIT
