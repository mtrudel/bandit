## 1.5.7 (1 Aug 2024)

### Changes

* Timeouts encountered while reading a request body will now result in a `408
  Request Timeout` being returned to the client by way of a `Bandit.HTTPError`
  being raised. Previously, a `:more` tuple was returned (#385, thanks
  @martosaur!)

## 1.5.6 (1 Aug 2024)

### Fixes

* Improve handling of the end of stream condition for HTTP/2 requests that send
  a body which isn't read by the Plug (#387, thanks @fekle!)

## 1.5.5 (19 Jun 2024)

### Changes

* Add `domain: [:bandit]` to the metadata of all logger calls
* Bring logging of early-connect HTTP2 errors under the `log_protocol_errors` umbrella

## 1.5.4 (14 Jun 2024)

### Changes

* Raise HTTP/2 send window timeouts as stream errors so that they're logged as
  protocol errors (thanks @hunterboerner!)

## 1.5.3 (7 Jun 2024)

### Changes

* Add `:short` and `:verbose` options to `log_protocol_errors` configuration
  option. **Change default value to `:short`, which will log protocol
  errors as a single summary line instead of a full stack trace**
* Raise `Bandit.HTTPError` errors when attempting to write to a closed client
  connection (except for chunk/2 calls, which now return `{:error, reason}`).
  Unless otherwise caught by the user, these errors will bubble out past the
  configured plug and terminate the plug process. This closely mimics the
  behaviour of Cowboy in this regard (#359)
* Respect the plug-provided content-length on HEAD responses (#353, thanks
  @meeq!)
* Minor changes to how 'non-system process dictionary entries' are identified

### Fixes

* No longer closes on HTTP/1 requests smaller than the size of the HTTP/2
  preamble
* Close deflate contexts more eagerly for reduced memory use

## 1.5.2 (10 May 2024)

### Fixes

* Don't crash on non-stringable process dictionary keys (#350, thanks
  @ryanwinchester, @chrismccord!)

## 1.5.1 (10 May 2024)

### Enhancements

* Process dictionary is now cleared of all non-system process dictionary entries
  between keepalive requests (#349)
* Explicitly run a GC before upgrading a connection to websocket (#348)
* Improve docs around deflate options (thanks @kotsius!)

## 1.5.0 (21 Apr 2024)

### Enhancements

* Bandit now respects an exception's conformance to `Plug.Exception` when
  determining which status code to return to the client (if the plug did not
  already send one). Previously they were always returned as 500 (for HTTP/1)
  or an 'internal error' stream error (for HTTP/2)
* Bandit now only logs the stacktrace of plug-generated exceptions whose status
  code (as determined by `Plug.Exception.status/1`) is contained within the new
  `log_exceptions_with_status_codes` configuration option (defaulting to
  `500..599`)
* As a corollary to the above, Bandit request handler processes no longer exit
  abnormally in the case of plug-generated exceptions

### Changes

* HTTP semantic errors encountered in an HTTP/2 request are returned to the
  client using their proper status code instead of as a 'protocol error' stream
  error

## 1.4.2 (2 Apr 2024)

### Enhancements

* Support top-level :inet and :inet6 options for Plug.Cowboy compatibility (#337)

## 1.4.1 (27 Mar 2024)

### Changes

* **BREAKING CHANGE** Move `log_protocol_errors` configuration option into
  shared `http_options` top-level config (and apply it to HTTP/2 errors as well)
* **BREAKING CHANGE** Remove `origin_telemetry_span_context` from WebSocket
  telemetry events
* **BREAKING CHANGE** Remove `stream_id` from HTTP/2 telemetry events
* Add `conn` to the metadata of telemetry start events for HTTP requests
* Stop sending WebSocket upgrade failure reasons to the client (they're still
  logged)

### Fixes

* Return HTTP semantic errors to HTTP/2 clients as protocol errors instead of
  internal errors

## 1.4.0 (26 Mar 2024)

> [!WARNING]
> **IMPORTANT** Phoenix users MUST upgrade to WebSockAdapter `0.5.6` or newer when
> upgrading to Bandit `1.4.0` or newer as some internal module names have changed

### Enhancements

* Complete refactor of HTTP/2. Improved process model is MUCH easier to
  understand and yields about a 10% performance boost to HTTP/2 requests (#286 /
  #307)
* Substantial refactor of the HTTP/1 and HTTP/2 stacks to share a common code
  path for much of their implementations, with the protocol-specific parts being
  factored out to a minimal `Bandit.HTTPTransport` protocol internally, which
  allows each protocol to define its own implementation for the minimal set of
  things that are different between the two stacks (#297 / #329)

### Changes

* **BREAKING CHANGE** Move configuration options that are common between HTTP/1
  and HTTP/2 stacks into a shared `http_options` top-level config
* **BREAKING CHANGE** The HTTP/2 header size limit options have been deprecated,
  and have been replaced with a single `max_header_block_size` option. The setting
  defaults to 50k bytes, and refers to the size of the compressed header block
  as sent on the wire (including any continuation frames)
* **BREAKING CHANGE** Remove `req_line_bytes`, `req_header_bytes`, `resp_line_bytes` and
  `resp_header_bytes` from HTTP/1 request telemetry measurements
* **BREAKING CHANGE** Remove `status`, `method` and `request_target` from
  telemetry metadata. All of this information can be obtained from the `conn`
  struct attached to most telemetry events
* **BREAKING CHANGE** Re-reading a body that has already been read returns `{:ok,
  "", conn}` instead of raising a `Bandit.BodyAlreadyReadError`
* **BREAKING CHANGE** Remove `Bandit.BodyAlreadyReadError`
* **BREAKING CHANGE** Remove h2c support via Upgrade header. This was deprecated
  in RFC9113 and never in widespread use. We continue to support h2c via prior
  knowledge, which remains the only supported mechanism for h2c in RFC9113
* Treat trailing bytes beyond the indicated content-length on HTTP/1 requests as
  an error
* Surface request body read timeouts on HTTP/1 requests as `{:more...}` tuples
  and not errors
* Socket sending errors are no longer surfaced on chunk sends in HTTP/1
* We no longer log if processes that are linked to an HTTP/2 stream process
  terminate unexpectedly. This has always been unspecified behaviour so is not
  considered a breaking change
* Calls of `Plug.Conn` functions for an HTTP/2 connection must now come from the
  stream process; any other process will raise an error. Again, this has always
  been unspecified behaviour
* We now send an empty DATA frame for explicitly zero byte bodies instead of
  optimizing to a HEADERS frame with end_stream set (we still do so for cases
  such as 204/304 and HEAD requests)
* We now send RST_STREAM frames if we complete a stream and the remote end is
  still open. This optimizes cases where the client may still be sending a body
  that we never consumed and don't care about
* We no longer explicitly close the connection when we receive a GOAWAY frame

## 1.3.0 (8 Mar 2024)

### Enhancements

* Run an explicit garbage collection between every 'n' keepalive requests on the same HTTP/1.1 connection in order to keep reported (but not actual!) memory usage from growing over time. Add `gc_every_n_keepalive_requests` option to configure this (default value of
  `5`). #322, thanks @ianko & @Nilsonn!)
* Add `log_protocol_errors` option to optionally quell console logging of 4xx errors generated by Bandit. Defaults to `true` for now; may switch to `false` in the future based on adoption (#321, thanks @Stroemgren!)

### Changes

* Don't send a `transfer-encoding` header for 1xx or 204 responses (#317, thanks
  @mwhitworth!)

## 1.2.3 (23 Feb 2024)

### Changes

* Log port number when listen fails (#312, thanks @jonatanklosko!)
* Accept mixed-case keepalive directives (#308, thanks @gregors!)

## 1.2.2 (16 Feb 2024)

### Changes

* Reset Logger metadata on every request

## 1.2.1 (12 Feb 2024)

### Changes

* Disable logging of unknown messages received by an idle HTTP/1 handler to
  avoid noise on long polling clients. This can be changed via the
  `log_unknown_messages` http_1 option (#299)

## 1.2.0 (31 Jan 2024)

### Enhancements

* Automatically pull in `:otp_app` value in Bandit.PhoenixAdapter (thanks
  @krns!)
* Include response body metrics for HTTP/1 chunk responses

### Fixes

* Fix broken HTTP/1 inform/3 return value (thanks @wojtekmach!)
* Maintain HTTP/1 read timeout after receiving unknown messages

## 1.1.3 (12 Jan 2024)

### Fixes

* Do not send a fallback response if the plug has already sent one (#288 & #289, thanks @jclem!)

### Changes

* Packagaing improvements (#283, thanks @wojtekmach!)

## 1.1.2 (20 Dec 2023)

### Fixes

* Fix support for proplist-style arguments (#277, thanks @jjcarstens!)
* Speed up WebSocket framing (#272, thanks @crertel!)
* Fix off-by-one error in HTTP2 sendfile (#269, thanks @OrangeDrangon!)
* Improve mix file packaging (#266, thanks @patrickjaberg!)

## 1.1.1 (14 Nov 2023)

### Fixes

* Do not advertise disabled protocols via ALPN (#263)

## 1.1.0 (2 Nov 2023)

### Changes

* Messages sent to Bandit HTTP/1 handlers no longer intentionally crash the
  handler process but are now logged in the same manner as messages sent to a
  no-op GenServer (#259)
* Messages regarding normal termination of monitored processes are no longer
  handled by the WebSocket handler, but are now passed to the configured
  `c:WebSock.handle_info/2` callback (#259)

### Enhancements

* Add support for `Phoenix.Endpoint.server_info/1` (now in Phoenix main; #258)
* Add support for `:max_heap_size` option in WebSocket handler (introduced in
  websock_adapter 0.5.5; #255, thanks @v0idpwn!)

## 1.0.0 (18 Oct 2023)

### Changes

* Remove internal tracking of remote `max_concurrent_streams` setting (#248)

## 1.0.0-pre.18 (10 Oct 2023)

### Fixes

* Fix startup when plug module has not yet been loaded by the BEAM

## 1.0.0-pre.17 (9 Oct 2023)

### Enhancements

* Support function based plugs & improve startup analysis of plug configuration
  (#236)
* Improve keepalive support when Plug does not read request bodies (#244)
* Improve logic around not sending bodies on HEAD requests (#242)

### Changes

* Internal refactor of WebSocket validation (#229)


## 1.0.0-pre.16 (18 Sep 2023)

### Changes

* Use protocol default port in the event that no port is provided in host header (#228)

### Fixes

* Improve handling of iolist response bodies (#231, thanks @travelmassive!)

## 1.0.0-pre.15 (9 Sep 2023)

### Fixes

* Fix issue with setting remote IP at connection startup (#227, thanks @jimc64!)

## 1.0.0-pre.14 (28 Aug 2023)

### Enhancements

* Add `Bandit.PhoenixAdapter.bandit_pid/2` (#212)
* Return errors to `Plug.Conn.Adapter.chunk/2` HTTP/1 calls (#216)

### Changes

* `Plug.Conn` function calls must come from the process on which `Plug.call/2` was called (#217, reverts #117)

## 1.0.0-pre.13 (15 Aug 2023)

### Enhancements

* Add ability to send preamble frames when closing a WebSock connection (#211)

## 1.0.0-pre.12 (12 Aug 2023)

## Fixes

* Bump ThousandIsland to 1.0.0-pre.7 to fix leaking file descriptors on
  `Plug.Conn.sendfile/5` calls (thanks @Hermanverschooten!)

## 1.0.0-pre.11 (11 Aug 2023)

## Changes

* **BREAKING CHANGE** Move `conn` value in telemetry events from measurements to metadata

## Enhancements

* Add `method`, `request_target` and `status` fields to telemetry metadata on HTTP stop events
* Improve RFC compliance regarding cache-related headers on deflated responses (#207, thanks @tanguilp!)
* Bump to Thousand Island `1.0.0-pre.6`
* Doc improvements (particularly around implementation notes)
* Typespec improvements (thanks @moogle19!)

## 1.0.0-pre.10 (28 Jun 2023)

## Enhancements

* Add support for `Plug.Conn.inform/3` on HTTP/1 connections (#180)
* Add support for h2c upgrades (#186, thanks @alisinabh!)
* Internal refactoring of HTTP/1 content-length encoded body reads (#184, #190,
  thanks @asakura & @moogle19!)

## Changes

* Bump Thousand Island to 1.0.0-pre.6 (gaining support for suspend/resume API)
* Drop Elixir 1.12 as a supported target (it should continue to work, but is no
  longer covered by CI)

## Fixes

* Fix crash when Plug used `Plug.Conn.get_peer_data/1` function on HTTP/1
  connections (#170, thanks @moogle19!)
* Fix port behaviour when connecting over unix socket (#176, thanks @asakura
  & @ibarchenkov!)

## 1.0.0-pre.9 (16 Jun 2023)

## Changes

* Use new ThousandIsland APIs for socket info (#167, thanks @asakura!)

## Fixes

* Handle nil connection close reason when closing a WebSocket

## 1.0.0-pre.8 (15 Jun 2023)

## Fixes

* Further improve logging on WebSocket upgrade errors (#149)

## 1.0.0-pre.7 (14 Jun 2023)

## Enhancements

* Refactor HTTP/1 read routines (#158 & #166, thanks @asakura!)
* Improve logging on WebSocket upgrade errors (#149)

## Changes

* Override any content-length headers that may have been set by Plug (#165)
* Send content-length on HTTP/2 responses where appropriate (#165)

## Fixes

* Send correct content-length header when sending deflated response (#151)
* Do not attempt to deflate if Plug sends a content-encoding header (#165)
* Improve corner case handling of content-length request header (#163, thanks
  @ryanwinchester!)
* Handle case where ThousandIsland returns error tuples on some helper routines
  (#162)

## 1.0.0-pre.6 (8 Jun 2023)

### Changes

* Always use the declaed scheme if declared in a request-line or `:scheme`
  pseudo-header (#159)
* Internal tidying (thanks @asakura!)

## 1.0.0-pre.5 (2 Jun 2023)

### Enhancements

* Total overhaul of typespecs throughout the library (thanks @asakura!)

## 1.0.0-pre.4 (23 May 2023)

### Enhancements

* Performance / correctness improvements to header length validation (#143,
  thanks @moogle19!)
* Performance improvements to host header port parsing (#145 & #147, thanks
  @ryanwinchester!)
* Improve WebSocket upgrade failure error messages to aid in diagnosis (#152)

### Changes

* Consolidate credo config (#146, thanks @ryanwinchester!)

### Fixes

* Fix error in suggested version dependencies during 1.0-pre series (#142,
  thanks @cvkmohan!)

## 1.0.0-pre.3 (3 May 2023)

### Enhancements

* Respect read timeout for HTTP/1 keepalives (#140)
* Support Websock 0.5.1, including support for optional `c:WebSock.terminate/2`
  (#131)

### Changes

* Use Req instead of Finch in tests (#137)
* Improve a few corner cases in tests (#136)

## 1.0.0-pre.2 (24 Apr 2023)

### Fixes

* Don't require transport_options to be a keyword list (#130, thanks @justinludwig!)

## 1.0.0-pre.1 (21 Apr 2023)

### Changes

* Update Thousand Island dependency to 1.0-pre

# Changelog for 0.7.x

## 0.7.7 (11 Apr 2023)

### Changes

* Bandit will now raise an error at startup if no plug is specified in config
  (thanks @moogle19!)

### Fixes

* Fix crash at startup when using `otp_app` option (thanks @moogle19!)
* Minor doc formatting fixes

## 0.7.6 (9 Apr 2023)

### Changes

* **BREAKING CHANGE** Rename top-level `options` field to `thousand_island_options`
* **BREAKING CHANGE** Rename `deflate_opts` to `deflate_options` where used
* Massive overhaul of documentation to use types where possible
* Bandit now uses a term of the form `{Bandit, ref()}` for `id` in our child spec
* Bumped to Thousand Island 0.6.7. `num_connections` is now 16384 by default

### Enhancements

* Added top level support for the following convenience parameters:
  * `port` can now be set at the top level of your configuration
  * `ip` can now be set at the top level of your configuration
  * `keyfile` and `certfile` can now be set at the top level of your configuration
* Transport options are now validated by `Plug.SSL.configure/1` when starting
  an HTTPS server
* Rely on Thousand Island to validate options specified in `thousand_island_options`. This should avoid cases like #125 in the future.

## 0.7.5 (4 Apr 2023)

### Changes

* Drop explicit support for Elixir 1.11 since we no longer test it in CI (should
  still work, just that it's now at-your-own-risk)
* Add logo to ex_doc and README

### Fixes

* Allow access to Thousand Island's underlying `shutdown_timeout` option
* Fix test errors that cropped up in OTP 26


## 0.7.4 (27 Mar 2023)

### Changes

* Calling `Plug.Conn` adapter functions for HTTP/2 based requests are no longer
  restricted to being called from the process which called `c:Plug.call/2`

### Enhancements

* Added `startup_log` to control whether / how Bandit logs the bound host & port
  at startup (Thanks @danschultzer)
* Improved logging when the configured port is in use at startup (Thanks
  @danschultzer)
* Update to Thousand Island 0.6.5

## 0.7.3 (20 Mar 2023)

### Enhancements

* Added advanced `handler_module` configuration option to `options`

### Fixes

* Support returning `x-gzip` as negotiated `content-encoding` (previously would
  negotiate a request for `x-gzip` as `gzip`)

## 0.7.2 (18 Mar 2023)

### Enhancements

* Added HTTP compression via 'Content-Encoding' negotiation, enabled by default.
  Configuration is available; see [Bandit
  docs](https://hexdocs.pm/bandit/Bandit.html#module-config-options) for details

### Changes

* Minor refactor of internal HTTP/2 plumbing. No user visible changes

## 0.7.1 (17 Mar 2023)

### Changes

* Update documentation & messaging to refer to RFC911x RFCs where appropriate
* Validate top-level config options at startup
* Revise Phoenix adapter to support new config options
* Doc updates

## 0.7.0 (17 Mar 2023)

### Enhancements

* Add configuration points for various parameters within the HTTP/1, HTTP/2 and
  WebSocket stacks. See [Bandit
  docs](https://hexdocs.pm/bandit/Bandit.html#module-config-options) for details

# Changelog for 0.6.x

## 0.6.11 (17 Mar 2023)

### Changes

* Modified telemetry event payloads to match the conventions espoused by
  `:telemetry.span/3`
* Default shutdown timeout is now 15s (up from 5s)

### Enhancements

* Update to Thosuand Island 0.6.4 (from 0.6.2)

## 0.6.10 (10 Mar 2023)

### Enhancements

* Support explicit setting of WebSocket close codes & reasons as added in WebSock
0.5.0

## 0.6.9 (20 Feb 2023)

### Enhancements

* Add comprehensive Telemetry support within Bandit, as documented in the
  `Bandit.Telemetry` module
* Update our ThousandIsland dependnecy to pull in Thousand Island's newly
  updated Telemetry support as documented in the `ThousandIsland.Telemetry`
  module
* Fix parsing of host / request headers which contain IPv6 addresses (#97).
  Thanks @derekkraan!

# Changes

* Use Plug's list of response code reason phrases (#96). Thanks @jclem!
* Minor doc updates

## 0.6.8 (31 Jan 2023)

### Changes

* Close WebSocket connections with a code of 1000 (instead of 1001) when
  shutting down the server (#89)
* Use 100 acceptor processes by default (instead of 10)
* Improvements to make WebSocket frame masking faster

## 0.6.7 (17 Jan 2023)

### Enhancements

* Remove logging entirely when client connections do not contain a valid protocol
* Refactor WebSocket support for about a 20% performance lift

### Bug Fixes

* Add `nodelay` option to test suite to fix artificially slow WebSocket perf tests

## 0.6.6 (11 Jan 2023)

### Enhancements

* Log useful message when a TLS connection is made to plaintext server (#74)

## 0.6.5 (10 Jan 2023)

### Enhancements

* Update Thousand Island to 0.5.15 (quiets logging in timeout cases)
* Quiet logging in when client connections do not contain a valid protocol
* Refactor HTTP/1 for about a 20% performance lift
* Add WebSocket support to CI benchmark workflow
* Doc updates

### Bug Fixes

* Allow multiple instances of Bandit to be started in the same node (#75)
* Improve error handling in HTTP/1 when protocol errors are encountered (#74)
