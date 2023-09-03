defmodule ReqHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      def req_http1_client(context) do
        start_finch(context)
        [req: build_req(context)]
      end

      def req_h2_client(context) do
        start_finch(context, protocol: :http2)
        [req: build_req(context)]
      end

      defp start_finch(context, overrides \\ []) do
        options =
          [
            conn_opts: [
              transport_opts: [
                verify: :verify_peer,
                cacertfile: Path.join(__DIR__, "../support/ca.pem")
              ]
            ]
          ]
          |> Keyword.merge(overrides)

        start_supervised!({Finch, name: context.test, pools: %{default: options}})
      end

      defp build_req(context) do
        Req.Request.new([])
        |> Req.Request.append_request_steps(base_url: &Req.Steps.put_base_url/1)
        |> Req.Request.register_options([:base_url, :finch])
        |> Req.Request.merge_options(
          base_url: context.base,
          finch: context.test
        )
      end
    end
  end
end
