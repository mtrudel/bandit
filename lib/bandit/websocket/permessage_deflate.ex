defmodule Bandit.WebSocket.PerMessageDeflate do
  @moduledoc false
  # Support for per-message deflate extension, per RFC7692§7

  @typedoc "Encapsulates the state of a WebSocket permessage-deflate context"
  @type t :: %__MODULE__{
          server_no_context_takeover: boolean(),
          client_no_context_takeover: boolean(),
          server_max_window_bits: 8..15,
          client_max_window_bits: 8..15,
          inflate_context: :zlib.zstream(),
          deflate_context: :zlib.zstream()
        }

  defstruct server_no_context_takeover: false,
            client_no_context_takeover: false,
            server_max_window_bits: 15,
            client_max_window_bits: 15,
            inflate_context: nil,
            deflate_context: nil

  @valid_params ~w[server_no_context_takeover client_no_context_takeover server_max_window_bits client_max_window_bits]

  def negotiate(requested_extensions, opts) do
    :proplists.get_all_values("permessage-deflate", requested_extensions)
    |> Enum.find_value(&do_negotiate/1)
    |> case do
      nil -> {nil, []}
      params -> {init(params, opts), "permessage-deflate": params}
    end
  end

  defp do_negotiate(params) do
    with params <- normalize_params(params),
         true <- validate_params(params) do
      resolve_params(params)
    else
      _ -> nil
    end
  end

  defp normalize_params(params) do
    params
    |> Enum.map(fn
      {"server_max_window_bits", true} -> {"server_max_window_bits", true}
      {"server_max_window_bits", value} -> {"server_max_window_bits", parse(value)}
      {"client_max_window_bits", true} -> {"client_max_window_bits", 15}
      {"client_max_window_bits", value} -> {"client_max_window_bits", parse(value)}
      value -> value
    end)
  end

  defp parse(value) do
    case Integer.parse(value) do
      {int_value, ""} -> int_value
      :error -> value
    end
  end

  defp validate_params(params) do
    no_invalid_params = params |> :proplists.split(@valid_params) |> elem(1) == []
    no_repeat_params = params |> :proplists.get_keys() |> length() == length(params)

    no_invalid_values =
      :proplists.get_value("server_no_context_takeover", params) in [:undefined, true] &&
        :proplists.get_value("client_no_context_takeover", params) in [:undefined, true] &&
        :proplists.get_value("server_max_window_bits", params, 15) in 8..15 &&
        :proplists.get_value("client_max_window_bits", params, 15) in 8..15

    no_invalid_params && no_repeat_params && no_invalid_values
  end

  # This is where we finally determine which parameters to accept. Note that we don't convert to
  # atoms until this stage to avoid potential atom exhaustion
  defp resolve_params(params) do
    @valid_params
    |> Enum.flat_map(fn param_name ->
      case :proplists.get_value(param_name, params) do
        :undefined -> []
        param -> [{String.to_existing_atom(param_name), param}]
      end
    end)
  end

  defp init(params, opts) do
    instance = struct(__MODULE__, params)
    inflate_context = :zlib.open()
    :ok = :zlib.inflateInit(inflate_context, fix_bits(-instance.client_max_window_bits))
    deflate_context = :zlib.open()

    :ok =
      :zlib.deflateInit(
        deflate_context,
        Keyword.get(opts, :level, :default),
        :deflated,
        fix_bits(-instance.server_max_window_bits),
        Keyword.get(opts, :mem_level, 8),
        Keyword.get(opts, :strategy, :default)
      )

    %{instance | inflate_context: inflate_context, deflate_context: deflate_context}
  end

  # https://www.erlang.org/doc/man/zlib.html#deflateInit-6
  defp fix_bits(-8), do: -9
  defp fix_bits(other), do: other

  # Note that we pass back the context to the caller even though it is unmodified locally

  def inflate(data, %__MODULE__{} = context) do
    inflated_data =
      context.inflate_context
      |> :zlib.inflate(<<data::binary, 0x00, 0x00, 0xFF, 0xFF>>)
      |> IO.iodata_to_binary()

    if context.client_no_context_takeover, do: :zlib.inflateReset(context.inflate_context)
    {:ok, inflated_data, context}
  rescue
    e -> {:error, "Error encountered #{inspect(e)}"}
  end

  def inflate(_data, nil), do: {:error, :no_compress}

  def deflate(data, %__MODULE__{} = context) do
    deflated_data =
      context.deflate_context
      |> :zlib.deflate(data, :sync)
      |> IO.iodata_to_binary()

    deflated_size = byte_size(deflated_data) - 4

    deflated_data =
      case deflated_data do
        <<deflated_data::binary-size(deflated_size), 0x00, 0x00, 0xFF, 0xFF>> -> deflated_data
        deflated -> deflated
      end

    if context.server_no_context_takeover, do: :zlib.deflateReset(context.deflate_context)
    {:ok, deflated_data, context}
  rescue
    e -> {:error, "Error encountered #{inspect(e)}"}
  end

  def deflate(_data, nil), do: {:error, :no_compress}

  def close(%__MODULE__{} = context) do
    :zlib.close(context.inflate_context)
    :zlib.close(context.deflate_context)
  end
end
