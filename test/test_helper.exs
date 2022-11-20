ExUnit.start(exclude: :external_conformance)

# Capture all logs so we're able to assert on logging done at info level in tests
Logger.configure(level: :debug)
Logger.configure_backend(:console, level: :warning)
