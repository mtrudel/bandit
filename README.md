# Bandit

[![Build Status](https://github.com/mtrudel/bandit/workflows/Elixir%20CI/badge.svg)](https://github.com/mtrudel/bandit/actions)
[![Hex.pm](https://img.shields.io/hexpm/v/bandit.svg?style=flat-square)](https://hex.pm/packages/bandit)

![Under Construction](http://textfiles.com/underconstruction/CoColosseumField5989Construction.gif)
![Under Construction](http://textfiles.com/underconstruction/MoMotorCity6508imagesconstruction.gif)
![Under Construction](http://textfiles.com/underconstruction/CoColosseumField5989Construction.gif)

[Documentation](https://hexdocs.pm/bandit/)

Bandit is a pure Elixir HTTP server for Plug apps. It is currently very much a WiP but is maturing quickly.

Bandit is built atop [Thousand Island](https://github.com/mtrudel/thousand_island) and as a result can provide scalable
and performant HTTP services out of the box. By being the simplest thing that can get from HTTP requests to a Plug
interface it is also simple and easy to understand. Bandit is written entirely in Elixir and has no runtime
dependencies other than Thousand Island and Plug.

## Project Goals

* Implement comprehensive support for HTTP/1.0 through HTTP/2.0 (and eventually beyond) backed by obsessive RFC
  literacy and automated conformance testing
* Aim for minimal internal policy and HTTP-level configuration. Delegate to Plug as much as possible, and only 
interpret requests to the extent necessary to safely manage a connection & fulfill the requirements of supporting Plug
* Define & provide a public API for WebSockets in the same vein as Plug to allow for Phoenix to support servers other than Cowboy
* Prioritize (in order): correctness, clarity, performance. Seek to remove the mystery of infrastructure code by being
approachable and easy to understand

## Installation

Bandit is [available in Hex](https://hex.pm/docs/publish). The package can be installed
by adding `bandit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bandit, "~> 0.1.0"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/bandit](https://hexdocs.pm/bandit).

# License

MIT
