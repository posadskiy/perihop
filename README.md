# PeriHop

Menu bar app for switching a Bluetooth keyboard + trackpad from one Mac to
another. Handles the unpair → re-pair → connect dance that macOS doesn't
offer as a built-in feature.

Bundles a compiled copy of [blueutil](https://github.com/toy/blueutil)
(`Vendor/blueutil`, universal arm64/x86_64) — end users don't need Homebrew
or anything else installed. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Build

```bash
./build.sh
open PeriHop.app
```

This produces `PeriHop.app` — a menu bar–only app (no Dock icon). Since it's
unsigned, the first launch may need a right-click → Open to get past
Gatekeeper.

For quick iteration during development you can also run it unbundled (it'll
show a Dock icon since `Info.plist`'s `LSUIElement` only applies inside a
real `.app` bundle):

```bash
swift run
```

## Usage

**First run** — click the menu bar icon. Devices already connected to this
Mac show up automatically — select the keyboard, trackpad, mouse, or
whatever else you want to switch between Macs, then Save. If a device isn't
connected yet, slide its switch to OFF then back to ON and use "Scan for
New Devices".

**Switching Macs** — click the menu bar icon → "Switch Devices". It unpairs
the selected devices on this Mac, then prompts you to power-cycle them so
they can be discovered again, then re-pairs and connects.

**Changing devices** — "Edit Devices…" re-runs the same scan/select flow.

Config is stored at `~/Library/Application Support/PeriHop/config.json`.

## Relation to bt-grab.command

`bt-grab.command` is the original manual script this app replaces — kept
here unmodified as a fallback / reference.
