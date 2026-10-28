defmodule HTTP1HeadParserReadsTest do
  # Counts calls to HeadParser.parse/2 with call_count tracing, which counts
  # calls from every process. Thus this module is not async: ExUnit runs it
  # after the async modules, when no other test calls the parser.
  use ExUnit.Case, async: false

  alias Bandit.HTTP1.HeadParser
  alias Bandit.HTTPTransport.Bandit.HTTP1.Socket, as: Impl

  defmodule ChunkTransport do
    @moduledoc false
    def recv(:chunks, _length, _timeout) do
      case Process.get(:chunks, []) do
        [chunk | rest] ->
          Process.put(:chunks, rest)
          {:ok, chunk}

        [] ->
          {:error, :timeout}
      end
    end
  end

  defp read_head([first | rest]) do
    ti_socket = %ThousandIsland.Socket{
      socket: :chunks,
      transport_module: ChunkTransport,
      read_timeout: 100,
      handshake_timeout: 100,
      silent_terminate_on_error: false,
      span: ThousandIsland.Telemetry.start_span(:connection, %{}, %{handler: __MODULE__}),
      peername: nil
    }

    socket = %Bandit.HTTP1.Socket{socket: ti_socket, buffer: first, opts: %{http_1: []}}
    Process.put(:chunks, rest)
    Impl.read_head!(socket)
  end

  defp count_parses(fun) do
    # trace_pattern/3 only matches functions of a loaded module
    Code.ensure_loaded!(HeadParser)
    1 = :erlang.trace_pattern({HeadParser, :parse, 2}, true, [:call_count])

    try do
      result = fun.()
      {:call_count, count} = :erlang.trace_info({HeadParser, :parse, 2}, :call_count)
      {count, result}
    after
      :erlang.trace_pattern({HeadParser, :parse, 2}, false, [:call_count])
    end
  end

  test "a head sent one byte per read is parsed again only when a line is complete" do
    headers = Enum.map_join(1..20, fn i -> "x-header-#{i}: #{String.duplicate("v", 500)}\r\n" end)
    req = "GET / HTTP/1.1\r\nhost: localhost\r\n" <> headers <> "\r\n"

    {count, {"GET", {nil, nil, nil, "/"}, read_headers, _socket}} =
      count_parses(fn -> read_head(for <<b <- req>>, do: <<b>>) end)

    assert length(read_headers) == 21
    # One parse for the first read, and one for each of the 23 lines
    assert count == 24
  end

  test "a long partial header line goes to the decode_packet loop without parsing again" do
    req = "GET / HTTP/1.1\r\nfoo: " <> String.duplicate("v", 20_000)

    {count, _} =
      count_parses(fn ->
        assert_raise Bandit.HTTPError, fn -> read_head(for <<b <- req>>, do: <<b>>) end
      end)

    # The first read and the read that completes the request line
    assert count == 2
  end
end
