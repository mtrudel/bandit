defmodule ReqHelpers do
  @moduledoc false

  defmacro __using__(_) do
    quote location: :keep do
      def req_http1_client(context) do
        [req: context |> req_opts() |> Req.new()]
      end

      def req_h2_client(context) do
        [req: context |> req_opts() |> put_in([:connect_options, :protocol], :http2) |> Req.new()]
      end

      defp req_opts(context) do
        [
          base_url: context.base,
          retry: false,
          compressed: false,
          raw: true,
          follow_redirects: false,
          connect_options: [
            transport_opts: [
              verify: :verify_peer,
              cacertfile: Path.join(__DIR__, "../support/ca.pem")
            ]
          ]
        ]
      end
    end
  end
end
