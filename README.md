# Bandit

Bandit is a pure Elixir HTTP/1.1 server for Plug apps. It is currently very much a WiP.

Bandit is being built out in between [Thousand Island](https://github.com/mtrudel/thousand_island) and
[HAP](https://github.com/mtrudel/hap) in order to facilitate socket-level encryption as required by the latter. Once HAP
is functional, the intent is to turn attention back to Bandit in order to build it out as a compelling alternative to
Cowboy. In the meantime however, what's here is largely provisional and should be taken with a grain of salt.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `bandit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bandit, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/bandit](https://hexdocs.pm/bandit).

