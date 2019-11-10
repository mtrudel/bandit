defmodule Bandit.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:thousand_island, path: "../thousand_island"},
      {:plug, "~> 1.8.1"}
    ]
  end
end
