# Bandit

[![Build Status](https://github.com/mtrudel/bandit/workflows/Elixir%20CI/badge.svg)](https://github.com/mtrudel/bandit/actions)
[![Hex.pm](https://img.shields.io/hexpm/v/bandit.svg?style=flat-square)](https://hex.pm/packages/bandit)

![Under Construction](http://textfiles.com/underconstruction/CoColosseumField5989Construction.gif)
![Under Construction](http://textfiles.com/underconstruction/MoMotorCity6508imagesconstruction.gif)
![Under Construction](http://textfiles.com/underconstruction/CoColosseumField5989Construction.gif)

[Documentation](https://hexdocs.pm/bandit/)

Bandit is a pure Elixir HTTP server for Plug apps. It is currently very much a WiP.

Bandit is being built out in between [Thousand Island](https://github.com/mtrudel/thousand_island) and
[HAP](https://github.com/mtrudel/hap) in order to facilitate socket-level encryption as required by the latter. Once HAP
is functional, the intent is to turn attention back to Bandit in order to build it out as a compelling alternative to
Cowboy. In the meantime however, what's here is largely provisional and should be taken with a grain of salt.

## Project Goals

* Implement robust yet minimal support for HTTP/1.0 through HTTP/2.0 (and eventually beyond)
* Support Websockets via a public API in the same vein as Plug to allow for Phoenix to support servers other than Cowboy
* Aim for simplicity by focusing solely on supporting the Plug interface and not being a general purpose HTTP server
* Eventual goal of a pure-Elixir stack from Phoenix all the way down to TCP sockets

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
