# HTTP/2 Handler

Included in this folder is a complete `ThousandIsland.Handler` based implementation of HTTP/2 as
defined in [RFC 9113](https://datatracker.ietf.org/doc/rfc9113). 

## Process model

Within a Bandit server, an HTTP/2 connection is modeled as a set of processes:

* 1 process per connection, a `Bandit.HTTP2.Handler` module implementing the
  `ThousandIsland.Handler` behaviour, and;
* 1 process per stream (i.e.: per HTTP request) within the connection, implemented as
  a `Bandit.HTTP2.StreamTask` Task

The lifetimes of these processes correspond to their role; a connection process lives for as long
as a client is connected, and a stream process lives only as long as is required to process
a single stream request within a connection. 

Connection processes are the 'root' of each connection's process group, and are supervised by
Thousand Island in the same manner that `ThousandIsland.Handler` processes are usually supervised
(see the [project README](https://github.com/mtrudel/thousand_island) for details).

Stream processes are not supervised by design. The connection process starts new stream processes as required, and does so
once a complete header block for a new stream has been received. It starts stream processes via
a standard `start_link` call, and manages the termination of the resultant linked stream processes
by handling `{:EXIT,...}` messages as described in the Elixir documentation. This approach is
aligned with the realities of the HTTP/2 model, insofar as if a connection process terminates
there is no reason to keep its constituent stream processes around, and if a stream process dies
the connection should be able to handle this without itself terminating. It also means that our
process model is very lightweight - there is no extra supervision overhead present because no such
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
   same module. Frames are applied against this struct in a vaguely FSM-like manner, using pattern 
   matching within the `Bandit.HTTP2.Connection.handle_frame/3` function. Any side-effects of
   received frames are applied in these functions, and an updated connection struct is returned to
   represent the updated connection state. These side-effects can take the form of starting stream
   tasks, conveying data to running stream tasks, responding to the client with various frames, or
   any number of other actions
4. This process is repeated every time we receive data from the client until the
   `Bandit.HTTP2.Connection` module indicates that the connection should be closed, either
   normally or due to error. Note that frame deserialization may end up returning a connection
   error if the parsed frames fail specific criteria (generally, the frame parsing modules are
   responsible for identifying errors as described in [section
   6](https://datatracker.ietf.org/doc/html/rfc9113#section-6) of RFC 9113). In these cases, the
   failure is passed through to the connection module for processing in order to coordinate an
   orderly shutdown or client notification as appropriate

## Processing requests

The details of a particular stream are contained within a `Bandit.HTTP2.Stream` struct
(as well as a `Bandit.HTTP2.StreamTask` process in the case of active streams). The
`Bandit.HTTP2.StreamCollection` module manages a collection of streams, allowing for the memory
efficient management of complete & yet unborn streams alongside active ones.

Once a complete header block has been read, a `Bandit.HTTP2.StreamTask` is started to manage the
actual calling of the configured `Plug` module for this server, using the `Bandit.HTTP2.Adapter`
module as the implementation of the `Plug.Conn.Adapter` behaviour. This adapter uses a simple
`receive` pattern to listen for messages sent to it from the connection process, a pattern chosen
because it allows for easy provision of the blocking-style API required by the `Plug.Conn.Adapter`
behaviour. Functions in the `Bandit.HTTP2.Adapter` behaviour which write data to the client use
`GenServer` calls to the `Bandit.HTTP2.Handler` module in order to pass data to the connection
process.

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
