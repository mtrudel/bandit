defmodule HTTP1HeadCorpus do
  @moduledoc "Sample request heads for Bandit.HTTP1.HeadParser's tests."

  @crlf "\r\n"

  def requests do
    %{
      "minimal" => head("GET / HTTP/1.1", [{"Host", "localhost:4000"}]),
      "curl" =>
        head("GET /api/v1/users?id=42 HTTP/1.1", [
          {"Host", "api.example.com"},
          {"User-Agent", "curl/8.7.1"},
          {"Accept", "*/*"}
        ]),
      "browser" =>
        head("GET /products/widgets/blue-widget-3000?ref=homepage&utm_source=news HTTP/1.1", [
          {"Host", "www.example.com"},
          {"Connection", "keep-alive"},
          {"sec-ch-ua", ~s("Chromium";v="129", "Not=A?Brand";v="8", "Google Chrome";v="129")},
          {"sec-ch-ua-mobile", "?0"},
          {"sec-ch-ua-platform", ~s("macOS")},
          {"Upgrade-Insecure-Requests", "1"},
          {"User-Agent",
           "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
             "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"},
          {"Accept",
           "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif," <>
             "image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"},
          {"Sec-Fetch-Site", "same-origin"},
          {"Sec-Fetch-Mode", "navigate"},
          {"Sec-Fetch-User", "?1"},
          {"Sec-Fetch-Dest", "document"},
          {"Referer", "https://www.example.com/"},
          {"Accept-Encoding", "gzip, deflate, br, zstd"},
          {"Accept-Language", "en-GB,en-US;q=0.9,en;q=0.8"},
          {"Cookie",
           "_ga=GA1.1.123456789.1700000000; session_id=9f86d081884c7d659a2feaa0c55ad015; " <>
             "theme=dark; _ga_ABC123=GS1.1.1700000000.1.1.1700000100.0.0.0"}
        ]),
      "api_lowercase" =>
        head("POST /v2/orders HTTP/1.1", [
          {"host", "orders.internal.svc.cluster.local"},
          {"content-type", "application/json"},
          {"content-length", "348"},
          {"authorization",
           "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.abc"},
          {"x-request-id", "4bf92f35-77b3-4da6-a3ce-929d0e0e4736"},
          {"traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
          {"x-forwarded-for", "203.0.113.7, 10.0.0.12"},
          {"x-forwarded-proto", "https"},
          {"accept", "application/json"},
          {"user-agent", "orders-client/2.3.1 (elixir; finch)"}
        ]),
      "big_cookie" =>
        head("GET /dashboard HTTP/1.1", [
          {"Host", "app.example.com"},
          {"Cookie", Enum.map_join(1..30, "; ", &"cookie_#{&1}=#{String.duplicate("v", 40)}")},
          {"Accept", "*/*"}
        ])
    }
  end

  defp head(request_line, headers) do
    IO.iodata_to_binary([
      request_line,
      @crlf,
      Enum.map(headers, fn {k, v} -> [k, ": ", v, @crlf] end),
      @crlf
    ])
  end
end
