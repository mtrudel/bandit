defmodule ReqHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      def req_http1_client(context) do
        name = Module.concat(context.module, context.test)
        start_finch(name)
        [req: build_req(base_url: context.base, finch: name)]
      end

      def req_h2_client(context) do
        name = Module.concat(context.module, context.test)
        start_finch(name, protocols: [:http2])
        [req: build_req(base_url: context.base, finch: name)]
      end

      defp start_finch(name, overrides \\ []) do
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

        start_supervised!({Finch, name: name, pools: %{default: options}})
      end

      defp build_req(opts) do
        Req.Request.new([])
        |> Req.Request.append_request_steps(base_url: &Req.Steps.put_base_url/1)
        |> Req.Request.register_options([:base_url, :finch])
        |> Req.Request.merge_options(opts)
      end
    end
  end
end
