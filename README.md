# Bandit

[![Build Status](https://github.com/mtrudel/bandit/workflows/Elixir%20CI/badge.svg)](https://github.com/mtrudel/bandit/actions)
[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/bandit)
[![Hex.pm](https://img.shields.io/hexpm/v/bandit.svg?style=flat&color=blue)](https://hex.pm/packages/bandit)

Bandit is an HTTP server for Plug and WebSock apps.

Bandit is written entirely in Elixir and is built atop [Thousand
Island](https://github.com/mtrudel/thousand_island). It can serve HTTP/1.x,
HTTP/2 and WebSocket clients over both HTTP and HTTPS. It is written with
correctness, clarity & performance as fundamental goals.

In [recent performance
tests](https://github.com/mtrudel/network_benchmark/blob/0b18a9b299b9619c38d2a70ab967831565121d65/benchmarks-09-2021.pdf),
Bandit's HTTP/1.x engine is up to 5x faster than Cowboy depending on the number of concurrent
requests. When comparing HTTP/2 performance, Bandit is up to 2.3x faster than Cowboy (this number
is likely even higher, as Cowboy was unable to complete many test runs without error). This is
possible because Bandit has been built from the ground up for use with Plug applications; this
focus pays dividends in both performance and also in the approachability of the code base.

Bandit also emphasizes correctness. Its HTTP/2 implementation scores 100% on the
[h2spec](https://github.com/summerwind/h2spec) suite in strict mode, and its
WebSocket implementation scores 100% on the
[Autobahn](https://github.com/crossbario/autobahn-testsuite) test suite.
Extensive test coverage, strict credo analysis and dialyzer coverage round out
a test suite that ensures that Bandit is and will remain a platform you can
count on.

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
* Become the go-to HTTP & low-level networking stack of choice for the Elixir community by being
  reliable, efficient, and approachable

## Project Status

* Complete support for running
  [Phoenix](https://github.com/phoenixframework/phoenix) applications (WebSocket
  support requires Phoenix 1.7+)
* Complete support of the [Plug API](https://github.com/elixir-plug/plug)
* Complete support of the [WebSock API](https://github.com/phoenixframework/websock)
* Complete server support for HTTP/1.x as defined in [RFC
  2616](https://datatracker.ietf.org/doc/html/rfc2616)
* Complete server support for HTTP/2 as defined in [RFC
  7540](https://datatracker.ietf.org/doc/html/rfc7540), comprehensively covered by automated
  [h2spec](https://github.com/summerwind/h2spec) conformance testing
* Complete server support for WebSockets as defined in [RFC
  6455](https://datatracker.ietf.org/doc/html/rfc6455), comprehensively covered by automated
  [Autobahn](https://github.com/crossbario/autobahn-testsuite) conformance testing. Per-message
  compression as defined in [RFC 7692](https://datatracker.ietf.org/doc/html/rfc7692) is also
  supported
* Extremely scalable and performant client handling at a rate up to 5x that of Cowboy for the same
  workload with as-good-or-better memory use

Any Phoenix or Plug app should work with Bandit as a drop-in replacement for
Cowboy; exceptions to this are errors (if you find one, please [file an
issue!](https://github.com/mtrudel/bandit/issues)) That having been said, Bandit
remains a young project and we're still not at a 1.0 state just yet. The road
there looks like this following:

* [x] `0.1.x` series: Proof of concept (along with [Thousand
  Island](https://github.com/mtrudel/thousand_island)) sufficient to support
  [HAP](https://github.com/mtrudel/hap)
* [x] `0.2.x` series: Revise process model to accommodate forthcoming HTTP/2 and WebSocket
  adapters
* [x] `0.3.x` series: Implement HTTP/2 adapter
* [x] `0.4.x` series: Re-implement HTTP/1.x adapter
* [x] `0.5.x` series: Implement WebSocket extension & Phoenix support
* [ ] `0.6.x` series: Comprehensive performance optimization & telemetry coverage (in progress)
* [ ] `0.7.x` series: Enhance startup options, general quality-of-life issues
* [ ] `0.8.x` series: Bake-in. Ready for general use, with a caveat that we're still not 1.0
* [ ] `1.x` series: Ready for general use, without reservation

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
Bandit.start_link(plug: MyApp.MyPlug)
```

## WebSocket Support

Bandit supports upgrading HTTP requests to WebSocket connections via the use of
the `Plug.Conn.upgrade_adapter/3` function and the `WebSock` API. For details, see the `Bandit`
documentation.

## Implementation Details

Bandit's HTTP/2 implementation is described in detail in its own [README](lib/bandit/http2/README.md). Similar documentation for the HTTP/1.x and WebSocket implementations is a work in progress.

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
    {:bandit, ">= 0.5.10"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/bandit](https://hexdocs.pm/bandit).

# License

MIT
