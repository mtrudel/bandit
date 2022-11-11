defmodule Benchmark.HTTPClient do
  @file Path.join(:code.priv_dir(:benchmark), "random_10k")
  @base_config [duration: 15, file: @file, hostname: "localhost", port: 4000]
  @protocols ["http/1.1", "h2c"]
  @concurrencies [1, 4, 16]
  @threads [1]
  @clients [1]

  def run(metadata \\ []) do
    %{metadata: metadata |> Enum.into(%{}), scenarios: run_scenarios()}
  end

  defp run_scenarios() do
    build_scenarios()
    |> Enum.map(fn scenario ->
      IO.puts("Running #{inspect(scenario)}")

      result =
        scenario
        |> run_benchmark(@base_config)
        |> parse_output()

      %{scenario: scenario |> Enum.into(%{}), result: result |> Enum.into(%{})}
    end)
  end

  defp build_scenarios() do
    for protocol <- @protocols,
        concurrency <- @concurrencies,
        threads <- @threads,
        clients <- @clients do
      [protocol: protocol, concurrency: concurrency, threads: threads, clients: clients]
    end
  end

  defp run_benchmark(scenario, config) do
    System.cmd("h2load", [
      "-p",
      scenario[:protocol],
      "-D",
      to_string(config[:duration]),
      "-d",
      config[:file],
      "-m",
      to_string(scenario[:concurrency]),
      "-t",
      to_string(scenario[:threads]),
      "-c",
      to_string(scenario[:clients]),
      "http://#{config[:hostname]}:#{config[:port]}"
    ])
  end

  defp parse_output({output, 0}) do
    [status, _traffic, _min_max_headers, ttr, ttc, ttfb, reqs, _newline] =
      output
      |> String.split("\n")
      |> Enum.take(-8)

    process_status(status)
    |> Keyword.merge(process_statline(ttr, "time_to_request"))
    |> Keyword.merge(process_statline(ttc, "time_to_connect"))
    |> Keyword.merge(process_statline(ttfb, "time_to_first_byte"))
    |> Keyword.merge(process_statline(reqs, "reqs_per_sec"))
  end

  defp process_status("status codes: " <> status) do
    status
    |> String.split(",")
    |> Enum.map(&String.split(&1, " ", trim: true))
    |> Enum.map(fn [count, code] -> {:"status_#{code}", String.to_integer(count)} end)
  end

  defp process_statline(<<_label::binary-17, stats::binary>>, name) do
    [min, max, mean, sd, _percentage] =
      stats
      |> String.split(" ", trim: true)
      |> Enum.map(&Float.parse/1)
      |> Enum.map(fn
        {value, "ms"} -> value * 1000
        {value, _} -> value
      end)

    ["#{name}_min": min, "#{name}_max": max, "#{name}_mean": mean, "#{name}_sd": sd]
  end
end
