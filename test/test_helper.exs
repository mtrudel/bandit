Path.wildcard(Path.join(__DIR__, "support/*.{ex,exs}")) |> Enum.each(&Code.require_file/1)
Application.ensure_all_started(Bandit)
ExUnit.start()

# Capture all logs so we're able to assert on logging done at info level in tests
Logger.configure(level: :debug)
Logger.configure_backend(:console, level: :warn)
