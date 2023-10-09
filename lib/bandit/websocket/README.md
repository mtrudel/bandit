# WebSocket Handler

Included in this folder is a complete `ThousandIsland.Handler` based implementation of WebSockets
as defined in [RFC 6455](https://datatracker.ietf.org/doc/rfc6455). 

## Upgrade mechanism

A good overview of this process is contained in this [ElixirConf EU
talk](https://www.youtube.com/watch?v=usKLrYl4zlY).

Upgrading an HTTP connection to a WebSocket connection is coordinated by code
contained within several libraries, including Bandit,
[WebSockAdapter](https://github.com/phoenixframework/websock_adapter), and
[Plug](https://github.com/elixir-plug/plug). 

The HTTP request containing the upgrade request is first passed to the user's
application as a standard Plug call. After inspecting the request and deeming it
a suitable upgrade candidate (via whatever policy the application dictates), the
user indicates a desire to upgrade the connection to a WebSocket by calling
`WebSockAdapter.upgrade/4`, which checks that the request is a valid WebSocket
upgrade request, and then calls `Plug.Conn.upgrade_adapter/3` to signal to
Bandit that the connection should be upgraded at the conclusion of the request.
At the conclusion of the `Plug.call/2` callback, `Bandit.Pipeline` will then
attempt to upgrade the underlying connection. As part of this upgrade process,
`Bandit.DelegatingHandler` will switch the Handler for the connection to be
`Bandit.WebSocket.Handler`. This will cause any future communication after the
upgrade process to be handled directly by Bandit's WebSocket stack.

## Process model

Within a Bandit server, a WebSocket connection is modeled as a single process.
This process is directly tied to the lifecycle of the underlying WebSocket
connection; when upgrading from HTTP/1, the existing HTTP/1 handler process
'magically' becomes a WebSocket process by changing which Handler the
`Bandit.DelegatingHandler` delegates to. 

The execution model to handle a given request is quite straightforward: at
upgrade time, the `Bandit.DelegatingHandler` will call `handle_connection/2` to
allow the WebSocket handler to initialize any startup state. Connection state is
modeled by the `Bandit.WebSocket.Connection` struct and module.

All data subsequently received by the underlying [Thousand
Island](https://github.com/mtrudel/thousand_island) library will result in
a call to `Bandit.WebSocket.Handler.handle_data/3`, which will then attempt to
parse the data into one or more WebSocket frames. Once a frame has been
constructed, it is them passed through to the configured `WebSock` handler by
way of the underlying `Bandit.WebSocket.Connection`.

# Testing

All of this is exhaustively tested. Tests are broken up primarily into `protocol_test.exs`, which
is concerned with aspects of the implementation relating to protocol conformance and
client-facing concerns, while `sock_test.exs` is concerned with aspects of the implementation
having to do with the WebSock API and application-facing concerns. There are also more
unit-style tests covering frame serialization and deserialization.

In addition, the `autobahn` conformance suite is run via a `System` wrapper & executes the entirety
of the suite against a running Bandit server.
