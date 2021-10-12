# Bandit

[![Build Status](https://github.com/mtrudel/bandit/workflows/Elixir%20CI/badge.svg)](https://github.com/mtrudel/bandit/actions)
[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/bandit)
[![Hex.pm](https://img.shields.io/hexpm/v/bandit.svg?style=flat&color=blue)](https://hex.pm/packages/bandit)

Bandit is an HTTP server for Plug apps.

Bandit is written entirely in Elixir and is built atop [Thousand
Island](https://github.com/mtrudel/thousand_island). It can serve HTTP/1.x and HTTP/2 clients over
both HTTP and HTTPS. It is written with correctness, clarity & performance as fundamental goals.

In [recent performance
tests](https://github.com/mtrudel/network_benchmark/blob/0b18a9b299b9619c38d2a70ab967831565121d65/benchmarks-09-2021.pdf),
Bandit's HTTP/1.x engine is up to 5x faster than Cowboy depending on the number of concurrent
requests. When comparing HTTP/2 performance, Bandit is up to 2.3x faster than Cowboy (this number
is likely even higher, as Cowboy was unable to complete many test runs without error). This is
possible because Bandit has been built from the ground up for use with Plug applications; this
focus pays dividends in both performance and also in the approachability of the code base.

Bandit also emphasizes correctness. Its HTTP/2 implementation scores 100% on the
[h2spec](https://github.com/summerwind/h2spec) suite in strict mode. Extensive units tests
(90%+ coverage for all non-legacy modules), credo analysis and dialyzer coverage round out a test suite that
ensures that Bandit is and will remain a platform you can count on.

Lastly, Bandit exists to demystify the lower layers of infrastructure code. In a world where
The New Thing is nearly always adding abstraction on top of abstraction, it's important to have
foundational work that is approachable & understandable by users above it in the stack.

## Project Goals

* Implement comprehensive support for HTTP/1.0 through HTTP/2 (and beyond) backed by obsessive RFC
  literacy and automated conformance testing
* Aim for minimal internal policy and HTTP-level configuration. Delegate to Plug as much as
  possible, and only interpret requests to the extent necessary to safely manage a connection
  & fulfill the requirements of supporting Plug
* Prioritize (in order): correctness, clarity, performance. Seek to remove the mystery of
  infrastructure code by being approachable and easy to understand
* Become the go-to HTTP & low-level networking stack of choice for the Elixir community by being
  reliable, efficient, and approachable

## Project Status

Bandit is still a young project, and much work remains before it is ready for production use. That
having been said, much progress has been made already. The project is progressing steadily
towards full Phoenix support, with a phased development plan focusing on one major set of features
at a time.

As of the current 0.4.x release series, Bandit features the following:

* Complete support of the [Plug API](https://github.com/elixir-plug/plug)
* Complete server support for HTTP/2 as defined in [RFC
  7540](https://datatracker.ietf.org/doc/html/rfc7540), comprehensively covered by automated
  [h2spec](https://github.com/summerwind/h2spec) conformance testing
* Complete server support for HTTP/1.x as defined in [RFC
  2616](https://datatracker.ietf.org/doc/html/rfc2616). Testing is nowhere near as comprehensive
  as for HTTP/2, but improving this is the primary goal of the 0.4.x release series
* Extremely scalable and performant client handling at a rate up to 5x that of Cowboy for the same
  workload with as-good-or-better memory use

Today, almost any non-Phoenix Plug app should work with Bandit as a drop-in replacement for
Cowboy. However, Bandit is still a long way away from being a drop-in solution for Phoenix apps.
There are three main pieces of work to be done in order for this to happen:

* Bandit does not yet support WebSocket connections. Implementing them is the main goal of the
  0.5.x release series. As part of this, we will also be proposing to the community a generalized
  WebSocket API abstraction in the same vein as Plug is to HTTP
* Bandit support must be added to Phoenix itself:
    * A Bandit-supported Phoenix Endpoint Adapter implementation is required. This is mostly
      blocked at the moment by Bandit's lack of WebSocket support
    * The work to integrate Bandit into the Phoenix configuration & startup process has not been done

  Integrating Bandit support into Phoenix is the main goal of the 0.7.x release series, and the majority of the
  work will be taking place as PRs against the Phoenix project, with some inevitable support work
  taking place on Bandit itself
* Finally, extensive real-world burn-in testing needs to be carried out by adventurous volunteers in
  order to gain confidence in the stability and real-world performance characteristics of Bandit.
  This is the main goal of the 0.8.x series, in order to ensure that Bandit's eventual 1.0 release
  is truly ready for prime time

To summarize, the roadmap to full Phoenix support and an eventual 1.0 release looks more or less
like the following:

* [x] `0.1.x` series: Proof of concept (along with [Thousand
  Island](https://github.com/mtrudel/thousand_island)) sufficient to support
  [HAP](https://github.com/mtrudel/hap)
* [x] `0.2.x` series: Revise process model to accommodate forthcoming HTTP/2 and WebSocket
  adapters
* [x] `0.3.x` series: Implement HTTP/2 adapter
* [ ] `0.4.x` series: Re-implement HTTP/1.x adapter
* [ ] `0.5.x` series: Implement WebSocket extension
* [ ] `0.6.x` series: Enhance startup options, complete & revise documentation & tests
* [ ] `0.7.x` series: Integrate with Phoenix
* [ ] `0.8.x` series: Bugfixes from a wider release to ensure a solid 1.0

## Usage

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

Bandit takes a number of options at startup, which are described in detail in the Bandit
[documentation](https://hexdocs.pm/bandit/Bandit.html). By far the most common stumbling block
encountered with configuration involves setting up an HTTPS server. Bandit is comparatively easy
to set up in this regard, with a working example looking similar to the following:

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

## Contributing

Contributions to Bandit are very much welcome! Before undertaking any substantial work, please
open an issue on the project to discuss ideas and planned approaches so we can ensure we keep
progress moving in the same direction.

All contributors must agree and adhere to the project's [Code of
Conduct](https://github.com/mtrudel/bandit/blob/main/CODE_OF_CONDUCT.md).

Security disclosures should be sent privately to mat@geeky.net.

## Installation

Bandit is [available in Hex](https://hex.pm/docs/publish). The package can be installed
by adding `bandit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bandit, "~> 0.4.1"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/bandit](https://hexdocs.pm/bandit).

# License

MIT
