# Security Policy

## Supported Versions

Only the latest release is supported. PeriHop is a small personal-scale tool
without a long-term-support branching model — please update to the latest
version before reporting an issue.

## Reporting a Vulnerability

Please **do not** open a public issue for security-relevant reports (e.g.
anything involving the link between the two Macs, code signing, or how
PeriHop handles Bluetooth pairing data).

Instead, use GitHub's private reporting flow:
[Report a vulnerability](https://github.com/posadskiy/perihop/security/advisories/new).

You should get an initial response within a few days. If confirmed, a fix
will be released and the advisory published with credit, unless you'd
prefer to remain anonymous.

## Scope notes

Release disk images are Developer ID signed and notarized. Reports about
Gatekeeper rejecting an official `PeriHop.dmg`, or about something that
bypasses Gatekeeper, or that could let an unpaired third party trigger
pairing or unpairing without user action, are in scope.
