defmodule Bandit.WebSocket.PerMessageDeflate do
  @moduledoc false
  # Support for per-message deflate extension, per RFC7692§7

  @typedoc "Encapsulates the state of a WebSocket permessage-deflate context"
  @type t :: %__MODULE__{
          server_no_context_takeover: boolean(),
          client_no_context_takeover: boolean(),
          server_max_window_bits: 8..15,
          client_max_window_bits: 8..15
        }

  defstruct server_no_context_takeover: false,
            client_no_context_takeover: false,
            server_max_window_bits: 15,
            client_max_window_bits: 15

  @valid_params ~w[server_no_context_takeover client_no_context_takeover server_max_window_bits client_max_window_bits]

  def negotiate(requested_extensions) do
    :proplists.get_all_values("permessage-deflate", requested_extensions)
    |> Enum.find_value(&do_negotiate/1)
    |> case do
      nil -> {nil, []}
      params -> {struct(__MODULE__, params), "permessage-deflate": params}
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
  # atoms until this stage to avoid potential atom exhausiotn
  defp resolve_params(params) do
    @valid_params
    |> Enum.flat_map(fn param_name ->
      case :proplists.get_value(param_name, params) do
        :undefined -> []
        param -> [{String.to_existing_atom(param_name), param}]
      end
    end)
  end
end
