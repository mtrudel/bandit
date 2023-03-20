# Changelog for 0.7.x

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
