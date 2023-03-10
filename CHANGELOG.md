# Changelog for 0.6.x

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
