ExUnit.start(exclude: :slow)

# Capture all logs so we're able to assert on logging done at info level in tests
Logger.configure(level: :debug)
:logger.update_handler_config(:default, :level, :warning)

# Tests receive log events through this one handler. See LoggerHelpers
LoggerHelpers.install()
