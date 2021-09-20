Path.wildcard(Path.join(__DIR__, "support/*.{ex,exs}")) |> Enum.each(&Code.require_file/1)
ExUnit.start()
Logger.configure(level: :warn)
