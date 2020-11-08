defmodule Bandit.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit,
      version: "0.1.1",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Bandit",
      description: "A pure-Elixir HTTP server built for Plug apps",
      source_url: "https://github.com/mtrudel/bandit",
      package: [
        files: ["lib", "test", "mix.exs", "README*", "LICENSE*"],
        maintainers: ["Mat Trudel"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/mtrudel/bandit"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:thousand_island, "~> 0.2"},
      {:plug, "~> 1.8"},
      {:httpoison, "~> 1.6", only: :test},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
