# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- The two Macs can link with a pairing code and hand the keyboard and trackpad over directly, including when the other Mac is asleep
- A switch connects an existing bond first, and pairs again only if the accessory is in range and still refuses
- The Mac that has the accessory keeps it from reconnecting until the other Mac confirms
- Plugging the accessory in is picked up as a pairing
- Shortcuts, a `perihop://` link, and a docked display can take or hand off the devices without opening the menu
- Closing the lid hands the devices to the other Mac when it answers, and waking does not steal them back

### Changed
- The release build is Apple Silicon only. The macOS 27 SDK deprecates x86_64
- Bluetooth control now uses IOBluetooth in the app instead of shelling out to blueutil
- "Switch Devices" is now "Use here" and "Hand off"
- The link key is stretched with PBKDF2, a Mac that fails the pairing code five times is ignored, and a changed identity has to be trusted before the next switch

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
