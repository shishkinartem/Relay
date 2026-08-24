# Telegram is the only upload destination

**Status:** Accepted
**Date:** 2026-08-23
**Supersedes:** the Google Drive half of
`docs/adr/2026-08-23-destination-credentials-in-app.md` and
`TECHNICAL_SPEC.md` §17.

## Context

`TECHNICAL_SPEC.md` §17 made Google Drive a first-class destination, and it was
implemented in full: OAuth 2.0 for desktop with PKCE, a loopback redirect,
resumable chunked uploads, session recovery, and a connect flow in Settings.

Then someone tried to use it. Before a single byte can move, a user has to open
the Google Cloud console, create a project, enable the Drive API, configure an
OAuth consent screen, add themselves as a test user, create a Desktop-app OAuth
client, and paste the client id into Relay. The console pushes a card-backed
free trial at the first screen, which reads as a hard requirement even though it
is not. And an app left in *Testing* has its refresh tokens expire after seven
days, so the whole thing has to be re-done weekly until the app is published.

None of that is Relay's doing, and none of it can be removed by writing better
instructions — the shortest honest instruction is still five console screens.
Dropbox was evaluated as a lighter replacement and rejected: it also requires a
developer app registration, and its free tier is 2 GB, about two hours of 1080p
recording. Anonymous link hosts (GoFile and similar) need nothing at all, but
put the recording behind a public URL, which is the wrong default for a screen
recording.

## Decision

Ship **Telegram alone**, and document how to lift its limit.

Google Drive is removed: `packages/upload_google_drive`, the loopback
authorization delivery, the `GOOGLE_CLIENT_ID` environment key, and the OAuth
machinery that existed only for it. Nothing generic is removed — the
`UploadDestination` and `DestinationSetup` contracts, the coordinator, retry and
resume semantics all stay exactly as they were, because they are what makes
adding a destination cheap.

Telegram's hosted 50 MB cap is answered where it is created rather than by
another provider: the **Local Bot API Server** raises it to 2000 MB, is
published by Telegram, and is free. README documents the whole flow — `api_id`
from my.telegram.org, Docker or a source build, the `logOut` call that a bot
needs before it can run locally, and the ordering trap that `logOut` blocks the
hosted API for ten minutes, which matters because the chat id is discovered
through it.

Persisted settings that still name `google_drive` are migrated to `telegram`
(schema v1 → v2) rather than left to the registry's fallback, so the stored
setting keeps naming what Send will actually do.

## Alternatives considered

- **Keep Drive and improve its instructions.** Rejected: the instructions were
  already correct and specific; the cost is the console, not the wording.
- **Replace Drive with Dropbox.** Rejected: one form instead of five screens is
  an improvement, but it is still a developer registration the end user cannot
  skip, for a 2 GB ceiling.
- **WebDAV** (Yandex.Disk, Nextcloud). Rejected for now, not on merit: it needs
  no developer registration at all and is the lightest of the options
  considered. It stays the obvious next destination if one is wanted.
- **An anonymous link host.** Rejected as a default: no account, but no
  authorization either — a screen recording routinely contains mail, tabs and
  chat windows, and a public URL is not the right place to put that by default.
- **Keep Drive registered but unlisted.** Rejected: an unreachable destination
  is dead code, and the settings screen is the only place that could reach it.

## Consequences

One destination, and the app can be connected end to end without leaving
Telegram — a bot token and a chat id, both obtained inside the messenger.

Recordings above 50 MB need the local server, which is a real setup cost, but
one that is paid on the user\'s own machine and does not involve a cloud console
or a payment method. Below that, nothing is needed at all.

`UploadDestinationRegistry` now holds a single entry. §15 still forbids
uploading to more than one destination automatically, and the registry, the
change-destination affordance in Settings and the per-destination capability
reporting all continue to work unchanged the moment a second one is added.
