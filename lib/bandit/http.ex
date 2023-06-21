defmodule Bandit.HTTP do
  @moduledoc false

  @spec build_transport_info(ThousandIsland.Socket.t()) ::
          {boolean(), ThousandIsland.Transport.socket_info(),
           ThousandIsland.Transport.socket_info(), :public_key.der_encoded() | nil,
           ThousandIsland.Telemetry.t()}
  def build_transport_info(socket) do
    secure? = ThousandIsland.Socket.secure?(socket)
    telemetry_span = ThousandIsland.Socket.telemetry_span(socket)

    with {:ok, local_info} <- ThousandIsland.Socket.sockname(socket),
         {:ok, peer_info} <- ThousandIsland.Socket.peername(socket) do
      peer_cert = if secure?, do: get_peer_cert!(socket), else: nil
      {secure?, local_info, peer_info, peer_cert, telemetry_span}
    else
      {:error, reason} -> raise "Unable to obtain local/peer info: #{inspect(reason)}"
    end
  end

  @spec get_peer_cert!(ThousandIsland.Socket.t()) :: nil | :public_key.der_encoded() | no_return()
  defp get_peer_cert!(socket) do
    case ThousandIsland.Socket.peercert(socket) do
      {:ok, cert} ->
        cert

      {:error, :no_peercert} ->
        nil

      {:error, reason} ->
        raise "Unable to obtain peer cert: #{inspect(reason)}"
    end
  end
end
