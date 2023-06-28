# Changelog for 0.7.x

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
* Support Websock 0.5.1, including support for optional c:Websock.terminate/2`
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
  restricted to being called from the process which called `Plug.call/2`

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
