# Contributing to PeriHop

Thanks for considering a contribution. PeriHop is a small, focused tool, so
the bar for "does this fit" is: does it help switch Bluetooth peripherals
between Macs, without adding configuration most people won't use.

## Development setup

Requirements: macOS 13+, Swift 5.9+ (ships with Xcode / Xcode Command Line
Tools — no full Xcode project needed).

```bash
git clone https://github.com/posadskiy/perihop.git
cd perihop
swift build
```

To run it as a real menu bar app (needed to test anything involving
`LSUIElement`, the app icon, or Bluetooth permissions properly):

```bash
./build.sh
open PeriHop.app
```

`swift run` also works for quick iteration, but shows a Dock icon since
`Info.plist` only applies inside a real `.app` bundle.

## Making changes

- Keep PRs focused — one change per PR is easier to review than a bundle of
  unrelated fixes.
- Match the existing code style: SwiftUI + a small MVVM split
  (`BluetoothController` wraps the `blueutil` process, `SwitchFlowViewModel`
  owns the switch state machine, views stay declarative). Avoid comments that
  restate what the code already says — only comment on non-obvious *why*.
- Test on real hardware if you can. This app's entire value is in the
  unpair/pair/connect dance actually working — a change that compiles but
  hasn't been run against a real keyboard/trackpad is only half-verified.
- If you touch `Vendor/blueutil`, note why in the PR description — it's a
  compiled binary vendored from [toy/blueutil](https://github.com/toy/blueutil)
  specifically so end users don't need Homebrew (see
  [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)).

## Submitting a PR

1. Fork the repo and create a branch off `main`.
2. Make your change, and update `README.md` or `CHANGELOG.md` if user-facing
   behavior changed.
3. Confirm `swift build -c release` succeeds.
4. Open a PR describing what changed and why. Screenshots/recordings are
   welcome for UI changes — this is a menu bar app, so a static diff doesn't
   show much.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/posadskiy/perihop/issues/new/choose).
For anything security-related, please use a
[private security advisory](https://github.com/posadskiy/perihop/security/advisories/new)
instead of a public issue — see [SECURITY.md](SECURITY.md).
