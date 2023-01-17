# Changelog for 0.6.x

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
