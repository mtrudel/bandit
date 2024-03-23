# HTTP/1 Handler

Included in this folder is a complete `ThousandIsland.Handler` based implementation of HTTP/1.x as
defined in [RFC 9112](https://datatracker.ietf.org/doc/rfc9112). 

## Process model

Within a Bandit server, an HTTP/1 connection is modeled as a single process.
This process is tied to the lifecycle of the underlying TCP connection; in the
case of an HTTP client which makes use of HTTP's keep-alive feature to make
multiple requests on the same connection, all of these requests will be serviced
by this same process. 

The execution model to handle a given request is quite straightforward: the
underlying [Thousand Island](https://github.com/mtrudel/thousand_island) library
will call `Bandit.HTTP1.Handler.handle_data/3`, which will then attempt to parse
the headers of the request by calling `Bandit.HTTP1.Adapter.read_headers/1`.
Assuming the common case, this list of headers will then be passed to 
`Bandit.Pipeline.run/6`, which will construct a `Plug.Conn` structure to
represent the request and subsequently pass it to the configured `Plug` module.

# Testing

All of this is exhaustively tested. Tests are located in `request_test.exs`, and
are broadly either concerned with testing network-facing aspects of the
implementation (ie: how well Bandit satisfies the relevant RFCs) or the Plug-facing 
aspects of the implementation.

Unfortunately, there is no HTTP/1 equivalent to the external h2spec test suite.
