defmodule Bandit.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit,
      version: "0.5.5",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      name: "Bandit",
      description: "A pure-Elixir HTTP server built for Plug  & Sock apps",
      source_url: "https://github.com/mtrudel/bandit",
      package: [
        files: ["lib", "test", "mix.exs", "README*", "LICENSE*"],
        maintainers: ["Mat Trudel"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/mtrudel/bandit"}
      ],
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:thousand_island, "~> 0.5.10"},
      {:sock, "~> 0.2.5"},
      {:plug, "~> 1.13"},
      {:hpax, "~> 0.1.1"},
      {:finch, "~> 0.8", only: [:dev, :test]},
      {:ex_doc, "~> 0.24", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [plt_core_path: "priv/plts", plt_file: {:no_warn, "priv/plts/dialyzer.plt"}]
  end

  defp docs do
    [main: "Bandit"]
  end
end
