defmodule Bandit.HTTP2.Errors do
  @moduledoc false
  # Errors as defined in RFC9113§7

  @typedoc "An error code as defined for GOAWAY and RST_STREAM errors"
  @type error_code() ::
          (no_error :: 0x0)
          | (protocol_error :: 0x1)
          | (internal_error :: 0x2)
          | (flow_control_error :: 0x3)
          | (settings_timeout :: 0x4)
          | (stream_closed :: 0x5)
          | (frame_size_error :: 0x6)
          | (refused_stream :: 0x7)
          | (cancel :: 0x8)
          | (compression_error :: 0x9)
          | (connect_error :: 0xA)
          | (enhance_your_calm :: 0xB)
          | (inadequate_security :: 0xC)
          | (http_1_1_requires :: 0xD)

  error_codes = %{
    no_error: 0x0,
    protocol_error: 0x1,
    internal_error: 0x2,
    flow_control_error: 0x3,
    settings_timeout: 0x4,
    stream_closed: 0x5,
    frame_size_error: 0x6,
    refused_stream: 0x7,
    cancel: 0x8,
    compression_error: 0x9,
    connect_error: 0xA,
    enhance_your_calm: 0xB,
    inadequate_security: 0xC,
    http_1_1_requires: 0xD
  }

  for {name, value} <- error_codes do
    @spec unquote(name)() :: unquote(Macro.var(name, Elixir)) :: unquote(value)
    def unquote(name)(), do: unquote(value)
  end

  # Represents a stream error as defined in RFC9113§5.4.2
  defmodule StreamError do
    defexception [:message, :error_code]
  end

  # Represents a stream error as defined in RFC9113§5.4.3
  defmodule ConnectionError do
    defexception [:message, :error_code]
  end
end
