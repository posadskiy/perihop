# PeriHop

[![Build](https://github.com/posadskiy/perihop/actions/workflows/build.yml/badge.svg)](https://github.com/posadskiy/perihop/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/posadskiy/perihop)](https://github.com/posadskiy/perihop/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](#requirements)

Menu bar app for switching a Bluetooth keyboard, trackpad, or mouse from one
Mac to another. macOS has no built-in way to do this — you either dig through
System Settings to unpair and re-pair by hand, or buy a $10 paid utility.
PeriHop does the unpair → re-pair → connect dance for you, automatically,
from the menu bar.

## Features

- **Menu bar only** — no Dock icon, no windows to manage
- **Pick any devices** — keyboard, trackpad, mouse, or any other Bluetooth
  accessory; not locked to a fixed "keyboard + trackpad" pair
- **Automatic reconnect** — after unpairing, PeriHop retries pairing in the
  background until you flip the device's switch off/on; no manual "continue"
  step
- **Zero dependencies** — bundles a compiled copy of
  [blueutil](https://github.com/toy/blueutil); no Homebrew or anything else
  to install
- **Universal binary** — runs natively on Apple Silicon and Intel

## Install

Download the latest build from [Releases](https://github.com/posadskiy/perihop/releases/latest),
unzip, and drag `PeriHop.app` to `/Applications`.

Since it's unsigned (no Apple Developer ID), the first launch needs a
right-click → **Open** to get past Gatekeeper, instead of a plain
double-click. macOS will also ask for Bluetooth access the first time you
scan for or switch devices — grant it in the prompt, or in
**System Settings → Privacy & Security → Bluetooth** if you missed it.

## Usage

**First run** — click the menu bar icon. Devices already connected to this
Mac show up automatically — select the keyboard, trackpad, mouse, or
whatever else you want to switch between Macs, then Save. If a device isn't
connected yet, slide its switch to OFF then back to ON and use "Scan for
New Devices".

**Switching Macs** — click the menu bar icon → "Switch Devices". It unpairs
the selected devices on this Mac, then automatically retries pairing and
connecting every few seconds — just slide each device's switch to OFF then
back to ON and it reconnects on its own, no need to click anything once
that starts. "Stop" halts retrying (the devices stay unpaired from this Mac
either way, since that's what makes them available to pair elsewhere).

**Changing devices** — "Edit Devices…" re-runs the same scan/select flow.

**Settings** — the gear icon in the popover has:
- **Launch at Login**
- **Show device addresses** — off by default; shows each device's MAC
  address under its name in Edit Devices, for troubleshooting.

Config is stored at `~/Library/Application Support/PeriHop/config.json`.

## Requirements

- macOS 13 (Ventura) or later
- A Bluetooth keyboard, trackpad, mouse, or other HID accessory

## Building from source

```bash
git clone https://github.com/posadskiy/perihop.git
cd perihop
./build.sh
open PeriHop.app
```

`build.sh` compiles for both Apple Silicon and Intel and `lipo`s them
together into one universal `.app` — no full Xcode install required, just
the Swift toolchain (ships with Xcode Command Line Tools).

For quick iteration you can also run it unbundled — this shows a Dock icon
though, since `Info.plist`'s `LSUIElement` only applies inside a real `.app`
bundle:

```bash
swift run
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## Contributing

Bug reports, feature requests, and PRs are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## Acknowledgments

- [blueutil](https://github.com/toy/blueutil) by Ivan Kuchin — the CLI
  PeriHop wraps for all Bluetooth operations. Bundled as a compiled
  universal binary; see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

[MIT](LICENSE)
