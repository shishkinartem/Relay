# Engineering Documentation

Start with:

1. `../CLAUDE.md` — always-on instructions, sources of truth, routing, validation
2. `../TECHNICAL_SPEC.md` — product and technical behavior, as amended by accepted ADRs

Then load only the topic relevant to the task. This split is intentional: `CLAUDE.md`
stays concise so permanent instructions do not crowd out task and code context.

## Architecture

| Doc | Covers |
|---|---|
| `ARCHITECTURE.md` | dependency direction, boundaries, extension axes, resource ownership |
| `architecture/recording.md` | session states, file lifecycle, recovery, idempotency |
| `architecture/media-pipeline.md` | capture, composition, encoding, backpressure, threading |
| `architecture/platform-abstraction.md` | the Flutter ↔ native boundary and the plugin packages |
| `architecture/platform-channel-contract.md` | every method channel, method and payload |
| `architecture/uploads.md` | the destination abstraction, Telegram, WebDAV, credentials |

## Development

| Doc | Covers |
|---|---|
| `development/testing.md` | what to run, the merge gate, coverage, release readiness |
| `development/design-system.md` | tokens, components, and the UI Definition of Done |
| `development/code-quality.md` | modularity, contracts, resource ownership, security |
| `development/compatibility-matrix.md` | what is actually built and verified, per platform |
| `development/macos-tcc-and-launchservices.md` | permission and launch-attribution diagnosis |
| `development/how-to-install.md` | building, installing and distributing builds — **in Russian**; the only documentation of `tool/install.sh` and of the Windows packaging story |

## Decisions

- `adr/README.md` — indexed list of all 12 recorded decisions, and when a new one is required

## Elsewhere in the repository

| Path | Covers |
|---|---|
| `../README.md` | running, building, permissions, connecting a destination, tests |
| `../tool/` | `validate.sh`, `install.sh`, `package-dmg.sh`, `reset-permissions.sh` |
| `../design/README.md` | the vendored connected design, how to view and refresh it |
| `../test/architecture_test.dart` | the layering rules, enforced rather than described |
