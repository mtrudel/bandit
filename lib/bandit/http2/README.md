# HTTP/2 Handler

Included in this folder is a complete `ThousandIsland.Handler` based implementation of HTTP/2 as
defined in [RFC 9110](https://datatracker.ietf.org/doc/rfc9110) & [RFC
9113](https://datatracker.ietf.org/doc/rfc9113)

## Process model

Within a Bandit server, an HTTP/2 connection is modeled as a set of processes:

* 1 process per connection, a `Bandit.HTTP2.Handler` module implementing the
  `ThousandIsland.Handler` behaviour, and;
* 1 process per stream (i.e.: per HTTP request) within the connection, implemented as
  a `Bandit.HTTP2.StreamProcess` process

Each of these processes model the majority of their state via a
`Bandit.HTTP2.Connection` & `Bandit.HTTP2.Stream` struct, respectively.

The lifetimes of these processes correspond to their role; a connection process lives for as long
as a client is connected, and a stream process lives only as long as is required to process
a single stream request within a connection.

Connection processes are the 'root' of each connection's process group, and are supervised by
Thousand Island in the same manner that `ThousandIsland.Handler` processes are usually supervised
(see the [project README](https://github.com/mtrudel/thousand_island) for details).

Stream processes are not supervised by design. The connection process starts new
stream processes as required, via a standard `start_link`
call, and manages the termination of the resultant linked stream processes by
handling `{:EXIT,...}` messages as described in the Elixir documentation. Each
stream process stays alive long enough to fully model an HTTP/2 stream,
beginning its life in the `:init` state and ending it in the `:closed` state (or
else by a stream or connection error being raised). This approach is aligned
with the realities of the HTTP/2 model, insofar as if a connection process
terminates there is no reason to keep its constituent stream processes around,
and if a stream process dies the connection should be able to handle this
without itself terminating. It also means that our process model is very
lightweight - there is no extra supervision overhead present because no such
supervision is required for the system to function in the desired way.

## Reading client data

The overall structure of the implementation is managed by the `Bandit.HTTP2.Handler` module, and
looks like the following:

1. Bytes are asynchronously received from ThousandIsland via the
   `Bandit.HTTP2.Handler.handle_data/3` function
2. Frames are parsed from these bytes by calling the `Bandit.HTTP2.Frame.deserialize/2`
   function. If successful, the parsed frame(s) are returned. We retain any unparsed bytes in
   a buffer in order to attempt parsing them upon receipt of subsequent data from the client
3. Parsed frames are passed into the `Bandit.HTTP2.Connection` module along with a struct of
   same module. Frames are processed via the `Bandit.HTTP2.Connection.handle_frame/3` function.
   Connection-level frames are handled within the `Bandit.HTTP2.Connection`
   struct, and stream-level frames are passed along to the corresponding stream
   process, which is wholly responsible for managing all aspects of a stream's
   state (which is tracked via the `Bandit.HTTP2.Stream` struct). The one
   exception to this is the handling of frames sent to streams which have
   already been closed (and whose corresponding processes have thus terminated).
   Any such frames are discarded without effect.
4. This process is repeated every time we receive data from the client until the
   `Bandit.HTTP2.Connection` module indicates that the connection should be closed, either
   normally or due to error. Note that frame deserialization may end up returning a connection
   error if the parsed frames fail specific criteria (generally, the frame parsing modules are
   responsible for identifying errors as described in [section
   6](https://datatracker.ietf.org/doc/html/rfc9113#section-6) of RFC 9113). In these cases, the
   failure is passed through to the connection module for processing in order to coordinate an
   orderly shutdown or client notification as appropriate

## Processing requests

The state of a particular stream are contained within a `Bandit.HTTP2.Stream`
struct, maintained within a `Bandit.HTTP2.StreamProcess` process. As part of the
stream's lifecycle, the server's configured Plug is called, with an instance of
the `Bandit.Adapter` struct being used to interface with the Plug. There
is a separation of concerns between the aspect of HTTP semantics managed by
`Bandit.Adapter` (roughly, those concerns laid out in
[RFC9110](https://datatracker.ietf.org/doc/html/rfc9110)) and the more
transport-specific HTTP/2 concerns managed by `Bandit.HTTP2.Stream` (roughly the
concerns specified in [RFC9113](https://datatracker.ietf.org/doc/html/rfc9113)).

# Testing

All of this is exhaustively tested. Tests are broken up primarily into `protocol_test.exs`, which
is concerned with aspects of the implementation relating to protocol conformance and
client-facing concerns, while `plug_test.exs` is concerned with aspects of the implementation
having to do with the Plug API and application-facing concerns. There are also more
unit-style tests covering frame serialization and deserialization.

In addition, the `h2spec` conformance suite is run via a `System` wrapper & executes the entirety
of the suite (in strict mode) against a running Bandit server.

## Limitations and Assumptions

Some limitations and assumptions of this implementation:

* This handler assumes that the HTTP/2 connection preface has already been consumed from the
  client. The `Bandit.InitialHandler` module uses this preface to discriminate between various
  HTTP versions when determining which handler to use
* Priority frames are parsed and validated, but do not induce any action on the part of the
  server. There is no priority assigned to respective streams in terms of processing; all streams
  are run in parallel as soon as they arrive
* While flow control is completely implemented here, the specific values used for upload flow
  control (that is, the end that we control) are fixed. Specifically, we attempt to maintain
  fairly large windows in order to not restrict client uploads (we 'slow-start' window changes
  upon receipt of first byte, mostly to retain parity between connection and stream window
  management since connection windows cannot be changed via settings). The majority of flow
  control logic has been encapsulated in the `Bandit.HTTP2.FlowControl` module should future
  refinement be required
