defmodule Bandit.HTTP3.Listener do
  @moduledoc false
  # Manages a QUIC/UDP listener for HTTP/3 connections.
  #
  # Wraps :quic_listener from the :quic Erlang package (~> 0.6, a pure Erlang
  # QUIC/RFC 9000 implementation). Each accepted QUIC connection results in a
  # Bandit.HTTP3.Handler GenServer being started to manage that connection's
  # lifetime.
  #
  # TLS is handled by QUIC itself (integrated TLS 1.3); this module loads
  # the cert and key from the already-configured SSL transport options and
  # passes them as DER binaries to :quic_listener.

  use GenServer

  require Logger

  @type opts :: [
          {:port, :inet.port_number()}
          | {:plug, Bandit.Pipeline.plug_def()}
          | {:opts, map()}
          | {:ssl_options, keyword()}
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec listener_info(pid()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def listener_info(pid) do
    GenServer.call(pid, :listener_info)
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so we can handle the :quic_listener process dying cleanly
    # rather than crashing silently.
    Process.flag(:trap_exit, true)

    port = Keyword.fetch!(opts, :port)
    plug = Keyword.fetch!(opts, :plug)
    handler_opts = Keyword.fetch!(opts, :opts)
    ssl_options = Keyword.fetch!(opts, :ssl_options)

    {cert_der, key_der} = extract_cert_and_key(ssl_options)

    # The connection_handler callback is invoked by :quic_listener for each
    # new QUIC connection. conn_pid is the library's internal connection
    # process; conn_ref is the opaque handle used to identify the connection
    # in subsequent :quic messages and send calls.
    connection_handler = fn conn_pid, conn_ref ->
      Bandit.HTTP3.Handler.start_link(conn_pid, conn_ref, plug, handler_opts)
    end

    quic_listener_opts = %{
      alpn: ["h3"],
      cert: cert_der,
      key: key_der,
      connection_handler: connection_handler
    }

    case :quic_listener.start_link(port, quic_listener_opts) do
      {:ok, listener_pid} ->
        Logger.debug("Bandit HTTP/3 listener started on UDP port #{port}")
        {:ok, %{listener_pid: listener_pid, port: port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:listener_info, _from, state) do
    # Return the bound address. :quic_listener may provide a way to query the
    # actual bound address (useful when port: 0 is used in tests); for now we
    # return the configured port with a wildcard address.
    {:reply, {:ok, {{0, 0, 0, 0}, state.port}}, state}
  end

  @impl GenServer
  # If the :quic_listener process exits, stop this GenServer with the same
  # reason so the supervisor can restart the whole listener stack.
  def handle_info({:EXIT, pid, reason}, %{listener_pid: pid} = state) do
    Logger.error("Bandit HTTP/3 :quic_listener exited: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Cert / key extraction
  # ---------------------------------------------------------------------------

  # Extract the cert (DER binary) and key (decoded Erlang term) from the SSL
  # options keyword list produced by Plug.SSL.configure/1.
  #
  # The cert is passed to :quic_listener as a DER binary.
  # The key must be a decoded key term that :quic_tls / :crypto.sign understand:
  #   - RSA: [E, N, D, P1, P2, E1, E2, C]  (big integers)
  #   - EC:  {:ECPrivateKey, ...}            (record as returned by der_decode)
  @spec extract_cert_and_key(keyword()) :: {binary(), term()}
  defp extract_cert_and_key(ssl_options) do
    cert_der =
      case Keyword.get(ssl_options, :cert) do
        nil ->
          ssl_options
          |> Keyword.fetch!(:certfile)
          |> File.read!()
          |> decode_pem_cert()

        der when is_binary(der) ->
          der
      end

    key =
      case Keyword.get(ssl_options, :key) do
        nil ->
          ssl_options
          |> Keyword.fetch!(:keyfile)
          |> File.read!()
          |> decode_pem_key()

        # :ssl stores pre-loaded keys as {type_atom, der_binary}
        {type, der} when is_binary(der) ->
          der |> then(&:public_key.der_decode(type, &1)) |> key_to_crypto()

        der when is_binary(der) ->
          der |> decode_pem_key()
      end

    {cert_der, key}
  end

  @spec decode_pem_cert(binary()) :: binary()
  defp decode_pem_cert(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        der

      _ ->
        raise Bandit.TransportError,
          message: "Unable to decode certificate from certfile for HTTP/3 listener",
          error: :bad_cert
    end
  end

  # Decode a PEM-encoded private key file and convert to the term that
  # :quic_tls / :crypto.sign accepts.
  @spec decode_pem_key(binary()) :: term()
  defp decode_pem_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        entry |> :public_key.pem_entry_decode() |> key_to_crypto()

      _ ->
        raise Bandit.TransportError,
          message: "Unable to decode private key from keyfile for HTTP/3 listener",
          error: :bad_key
    end
  end

  # Convert a decoded public_key record to the format :crypto.sign expects.
  #   RSA -> [E, N, D, P1, P2, E1, E2, C]
  #   EC  -> the ECPrivateKey record as-is (quic_tls pattern-matches on it)
  @spec key_to_crypto(term()) :: term()
  defp key_to_crypto({:RSAPrivateKey, _, n, e, d, p1, p2, e1, e2, c, _}) do
    [e, n, d, p1, p2, e1, e2, c]
  end

  defp key_to_crypto({:ECPrivateKey, _, _, _, _, _} = ec_key) do
    ec_key
  end
end
