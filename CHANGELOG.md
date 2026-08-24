# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `BluetoothController` is now genuinely `async` (continuation-based `Process` handling) instead of blocking a thread inside `Task.detached` at every call site
- Reconnect/retry logic now uses a generation-token guard so a stale attempt can't clobber a newer `retry()`'s result
- Device addresses are a distinct `DeviceAddress` type instead of raw `String`
- `DeviceStatus.pending` split into `.unknown` (never checked) and `.disconnected` (checked, not connected)
- blueutil's timeout watchdog now escalates from SIGTERM to SIGKILL if the process doesn't respond
- Config save failures now surface in the UI instead of failing silently

### Added
- Unit test target (Swift Testing) covering `DeviceListParser`, `DeviceConfig`/`DeviceAddress` round-tripping, and `SwitchFlowViewModel`'s retry/timeout state machine via a mock `BluetoothControlling`
- Unified logging (`os.Logger`) for Bluetooth operations and switch-flow state transitions

## [0.1.0] - 2026-08-24

### Added
- Menu bar app for switching Bluetooth keyboard/trackpad/mouse between Macs
- Multi-select device setup — pick any combination of paired/discoverable devices, not fixed keyboard+trackpad roles
- Automatic reconnect after unpair — retries pairing in the background, no manual "Continue" step
- Bundled, self-contained `blueutil` binary — no Homebrew required
- Universal binary (Apple Silicon + Intel)
- Launch at Login and "show device addresses" settings
- App icon
- Info panel (author, website, support email, version)
