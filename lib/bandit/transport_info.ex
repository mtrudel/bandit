defmodule Bandit.TransportInfo do
  @moduledoc false

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
      {:error, reason} -> raise "Unable to obtain transport_info: #{inspect(reason)}"
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
end
