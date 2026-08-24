# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
