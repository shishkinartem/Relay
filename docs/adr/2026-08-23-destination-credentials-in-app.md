# Destinations are connected in the application, not in `.env`

**Status:** Accepted; the Google Drive parts superseded
**Date:** 2026-08-23
**Superseded in part by:** `docs/adr/2026-08-23-telegram-only-destination.md`,
which removes Google Drive. Everything here about the setup contract, verifying
before storing, secrets in OS storage and `.env` as a seed still stands and is
what Telegram uses.

## Context

`TECHNICAL_SPEC.md` §16 specified Telegram credentials as `TELEGRAM_BOT_TOKEN`
and `TELEGRAM_CHAT_ID` read from a `.env` file, "acceptable for development or a
trusted internal deployment". §17 specified Google Drive as OAuth 2.0 for
desktop with a loopback redirect and PKCE.

Both were implemented; neither could be reached. There was no user interface
that set a Telegram credential, and `GoogleDriveSignIn` — the loopback flow —
was written and never called from anywhere. The only way to connect a
destination was to edit a file next to the binary and relaunch, and the only way
to discover that was to read the source. Telegram's own pre-flight error already
said "Add a bot token and a chat id in Settings", which did not exist.

This is the credential trust model, which `docs/adr/README.md` lists as
ADR-required.

## Decision

A destination declares what it needs; Settings renders it.

`UploadDestination` gains a `DestinationSetup` — a kind (`credentials` or
`interactive`), an action label, ordered plain-language steps, and typed
`DestinationField`s — plus `isConnected`, `connect`, `disconnect` and
`storedSetupValues`. One screen renders any destination from that description,
so adding S3 or OneDrive later means adding an implementation and registering
it, exactly as §14 requires of the upload path itself.

**Credentials live in OS-backed secure storage**, the same `CredentialStore`
that §17 already required for refresh tokens: the macOS Keychain and the Windows
Credential Manager. A Telegram bot token is written there, never to a file
beside the binary.

**`.env` is demoted to a seed.** A deployment may still ship
`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `GOOGLE_CLIENT_ID` to preconfigure a
build. Anything connected in the application takes precedence, and an explicit
disconnect survives a restart rather than silently falling back to the
deployment's own bot.

**Credentials are verified before they are stored.** Telegram calls `getMe` and
`getChat`; a mistyped token or a chat the bot cannot see is reported in the
connect screen, not at the end of a recording (§14's fail-fast rule, applied to
setup).

**The Google client id is enterable in the application.** An installed app's
client id is a public identifier, not a secret — PKCE is the secret half of that
flow — so a build that shipped without one is not a dead end. Changing it drops
the stored refresh token, which was issued to the previous client and is
worthless to the new one.

The browser half of the OAuth flow stays injected into the Drive destination
from the application layer: the loopback listener and `url_launcher` are
`dart:io` and platform launching, which `upload_google_drive` deliberately does
not own.

## Alternatives considered

- **Document `.env` in the README and stop there.** Rejected: it leaves a
  desktop application whose advertised feature cannot be used without a text
  editor, and it keeps a bot token in a plain file when the OS offers a keychain
  the project already depends on.
- **A screen per destination.** Rejected: two screens that differ only in their
  strings, and a third one to write for every destination added later — the
  branch-per-destination shape §14 exists to avoid.
- **Keep the Google client id in `.env` only.** Rejected: it is not a secret, and
  making it the one value that cannot be supplied in the application means a
  build without it can never connect Drive at all.
- **Store credentials in the settings JSON document.** Rejected: §27 forbids
  secrets in plain application preferences, and the secure store is already
  wired for the refresh token.

## Consequences

`TECHNICAL_SPEC.md` §16's "environment file" configuration is now the seed path
rather than the only path; §27's rule that secrets never reach `.env`, source or
logs is satisfied for Telegram too, not just for OAuth tokens.

The public-distribution caveat in §16 is unchanged: a bot token on an end user's
machine is that user's own token now, but a token shipped inside a distributed
binary is still not a secret. That redesign — a backend or proxy — remains
future work, and this decision does not foreclose it.

`UploadDestination` grew four methods and a description. Every implementation
must answer them, including test fakes.
