defmodule FinchHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      def finch_http1_client(_context), do: finch_for(:http1)
      def finch_h2_client(_context), do: finch_for(:http2)

      defp finch_for(protocol) do
        finch_name = self() |> inspect() |> String.to_atom()

        opts = [
          name: finch_name,
          pools: %{
            default: [
              size: 50,
              count: 1,
              protocol: protocol,
              conn_opts: [
                transport_opts: [
                  verify: :verify_peer,
                  cacertfile: Path.join(__DIR__, "../support/ca.pem")
                ]
              ]
            ]
          }
        ]

        {:ok, _} = start_supervised({Finch, opts})
        [finch_name: finch_name]
      end
    end
  end
end
