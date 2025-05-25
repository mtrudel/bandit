defmodule Bandit.TransportInfo do
  @moduledoc false

  @spec conn_info(ThousandIsland.Socket.t()) :: Bandit.Pipeline.conn_info()
  def conn_info(socket) do
    secure? = ThousandIsland.Socket.secure?(socket)

    {peer_address, _port} =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, peername} -> map_address(peername)
        {:error, reason} -> transport_error!("Unable to obtain conn_info", reason)
      end

    {secure?, peer_address}
  end

  @spec peer_data(ThousandIsland.Socket.t()) :: Plug.Conn.Adapter.peer_data()
  def peer_data(socket) do
    with {:ok, peername} <- ThousandIsland.Socket.peername(socket),
         {address, port} <- map_address(peername),
         {:ok, ssl_cert} <- peercert(socket) do
      %{address: address, port: port, ssl_cert: ssl_cert}
    else
      {:error, reason} -> transport_error!("Unable to obtain peer_data", reason)
    end
  end

  defstruct secure?: nil, sockname: nil, peername: nil, peercert: nil

  @typedoc "A struct for defining details of a transport"
  @type t :: %__MODULE__{
          secure?: boolean(),
          sockname: ThousandIsland.Transport.socket_info(),
          peername: ThousandIsland.Transport.socket_info(),
          peercert: :public_key.der_encoded() | nil
        }

  @spec init(ThousandIsland.Socket.t()) :: t()
  def init(socket) do
    with {:ok, sockname} <- ThousandIsland.Socket.sockname(socket),
         {:ok, peername} <- ThousandIsland.Socket.peername(socket),
         {:ok, peercert} <- peercert(socket) do
      %__MODULE__{
        secure?: ThousandIsland.Socket.secure?(socket),
        sockname: sockname,
        peername: peername,
        peercert: peercert
      }
    else
      {:error, reason} ->
        raise Bandit.TransportError, message: "Unable to obtain transport_info", error: reason
    end
  end

  @spec peer_data(t()) :: Plug.Conn.Adapter.peer_data()
  def peer_data(%__MODULE__{peername: peername, peercert: peercert}) do
    case peername do
      {:local, path} -> %{address: {:local, path}, port: 0, ssl_cert: peercert}
      {:unspec, <<>>} -> %{address: :unspec, port: 0, ssl_cert: peercert}
      {:undefined, term} -> %{address: {:undefined, term}, port: 0, ssl_cert: peercert}
      {ip, port} -> %{address: ip, port: port, ssl_cert: peercert}
    end
  end

  @spec peercert(ThousandIsland.Socket.t()) ::
          {:ok, :public_key.der_encoded() | nil} | {:error, term()}
  defp peercert(socket) do
    case ThousandIsland.Socket.peercert(socket) do
      {:ok, cert} -> {:ok, cert}
      {:error, :no_peercert} -> {:ok, nil}
      {:error, :not_secure} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_address(address) do
    case address do
      {:local, path} -> {{:local, path}, 0}
      {:unspec, <<>>} -> {:unspec, 0}
      {:undefined, term} -> {{:undefined, term}, 0}
      {ip, port} -> {ip, port}
    end
  end

  defp transport_error!(message, error) do
    raise Bandit.TransportError, message: message, error: error
  end
end
