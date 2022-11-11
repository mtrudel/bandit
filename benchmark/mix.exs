defmodule Benchmark.MixProject do
  use Mix.Project

  def project do
    [
      app: :benchmark,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:muontrap, "~> 1.0", optional: true},
      {:jason, ">= 0.0.0"},
      {:plug, "~> 1.14"}
    ]
  end
end
