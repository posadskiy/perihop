# Security Policy

## Supported Versions

Only the latest release is supported. PeriHop is a small personal-scale tool
without a long-term-support branching model — please update to the latest
version before reporting an issue.

## Reporting a Vulnerability

Please **do not** open a public issue for security-relevant reports (e.g.
anything involving the bundled `blueutil` binary, code signing, or how
PeriHop handles Bluetooth pairing data).

Instead, use GitHub's private reporting flow:
[Report a vulnerability](https://github.com/posadskiy/perihop/security/advisories/new).

You should get an initial response within a few days. If confirmed, a fix
will be released and the advisory published with credit, unless you'd
prefer to remain anonymous.

## Scope notes

PeriHop is unsigned and ad-hoc code-signed (no Apple Developer ID) — macOS
Gatekeeper already surfaces this to users on first launch. Reports about
"the app is unsigned" are expected and not considered a vulnerability on
their own; reports about something that *bypasses* Gatekeeper's warning, or
that could let an unpaired third party trigger pairing/unpairing without
user action, are very much in scope.
