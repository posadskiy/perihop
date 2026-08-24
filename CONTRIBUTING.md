# Contributing to PeriHop

Thanks for considering a contribution. PeriHop is a small, focused tool, so
the bar for "does this fit" is: does it help switch Bluetooth peripherals
between Macs, without adding configuration most people won't use.

## Development setup

Requirements: macOS 13+ to run the app, Swift 6.0+ toolchain to build it
(ships with Xcode / Xcode Command Line Tools — no full Xcode project needed).

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

## Testing

```bash
swift test
```

`SwitchFlowViewModel`'s retry/timeout state machine runs against a mock
(`BluetoothControlling`), not real hardware, so those tests are fast and
deterministic. `DeviceListParser` and `DeviceConfig` have their own
round-trip/parsing tests.

If `swift test` fails with `no such module 'Testing'` or a `dlopen` error
about `Testing.framework`, you're likely on Xcode Command Line Tools only
(no full Xcode) — Swift Testing isn't in the default runtime search path
there yet. Point the linker at it directly:

```bash
swift test \
  -Xswiftc -F -Xswiftc "/Library/Developer/CommandLineTools/Library/Developer/Frameworks" \
  -Xlinker -F -Xlinker "/Library/Developer/CommandLineTools/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "/Library/Developer/CommandLineTools/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
```

CI runs on GitHub's `macos-latest` runners, which ship full Xcode, so this
isn't needed there.

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
3. Confirm `swift build -c release` and `swift test` both succeed.
4. Open a PR describing what changed and why. Screenshots/recordings are
   welcome for UI changes — this is a menu bar app, so a static diff doesn't
   show much.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/posadskiy/perihop/issues/new/choose).
For anything security-related, please use a
[private security advisory](https://github.com/posadskiy/perihop/security/advisories/new)
instead of a public issue — see [SECURITY.md](SECURITY.md).
