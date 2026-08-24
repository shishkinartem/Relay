# WebDAV is the second destination

**Status:** Accepted
**Date:** 2026-08-23
**Amends:** `docs/adr/2026-08-23-telegram-only-destination.md`, which shipped
Telegram alone and named WebDAV "the obvious next destination if one is
wanted". One is wanted.

## Context

Telegram is reachable in a minute and needs nothing but the messenger, which is
why it is the default. Its hosted Bot API refuses a video over 50 MB, though —
about a minute and a half at 1080p30, three and a half at 720p30 — and the only
way past that is a Bot API server the user runs and keeps running. That is a
fair trade for a bug repro; it is not a way to store a forty-minute session.

So the question was which second destination costs a user the least. Measured by
what has to happen before the first byte moves:

| | Free | Before the first upload |
|---|---|---|
| WebDAV (Koofr) | 10 GB | sign up, generate an app password in account settings |
| Backblaze B2 | 10 GB | sign up, create a bucket, create an application key, copy two secrets |
| Dropbox | 2 GB | sign up, register a developer app, ship its app key in the build |
| Google Drive | 15 GB | the five console screens that got it removed |
| Yandex.Disk | 10 GB | app password — but WebDAV is throttled to roughly a minute per megabyte |

## Decision

Add a **WebDAV** destination, and document **Koofr** as the provider to use.

WebDAV is a protocol, so one implementation reaches Koofr, any Nextcloud or
ownCloud, Box and others. Changing provider is a different URL in a text field,
not a different package. Nothing in it is provider-specific: Koofr appears in
the setup steps and in a field hint, never in the code.

Authentication is HTTP Basic with an **app password** — issued from the
provider's own account settings, revocable on its own, and stored in the OS
credential store like every other secret (§27). There is no OAuth, no client id,
no consent screen and nothing that expires.

`connect` proves the account is usable before storing anything: `PROPFIND` for
the credentials, then `MKCOL` for the recordings folder, so a wrong address, a
rejected password or a read-only account is reported in the connect screen
rather than after a recording.

Transfer is a single streaming `PUT`. The file is read as it is sent, so memory
does not grow with the recording; progress, cancellation and the stall deadline
work exactly as they do for Telegram.

**No resume.** WebDAV has no standard way to continue a partial `PUT` —
`Content-Range` on `PUT` is an extension no provider is obliged to implement —
so an interrupted transfer restarts, and `UploadCapabilities.supportsResume` is
false rather than claiming otherwise. The retry policy still applies; §13 still
guarantees the local file survives a failure.

Telegram stays the default. It needs no setup at all, and a destination that
requires none should not be replaced by one that requires some.

## Alternatives considered

- **Backblaze B2.** Same 10 GB and no card, but a bucket, a key id and an
  application key — four fields and a web console, which is the shape this
  project has twice decided to walk away from.
- **Dropbox.** Rejected in `2026-08-23-telegram-only-destination.md` and not
  revisited: a developer registration for a 2 GB ceiling.
- **Yandex.Disk over the same WebDAV code.** It would work, and it is ruled out
  by the provider rather than by us: WebDAV transfers there are throttled to
  roughly 60 seconds per megabyte, which makes a 50 MB recording an hour-long
  upload. The implementation does not forbid it; the documentation does not
  suggest it.
- **An anonymous link host.** Still rejected: no account, but no authorization
  either, and a screen recording is not a thing to put behind a public URL by
  default.
- **Chunked upload with a resume extension.** Rejected as speculative: it would
  be written against one provider\'s extension and silently degrade on the rest.

## Consequences

Two destinations, neither of which needs a developer account, a console or a
payment method. The size ceiling now has an answer that does not involve running
a server: Telegram for what fits in a chat, WebDAV for what does not.

`UploadDestinationRegistry` holds two entries again, so the destination choice
in Settings is a real choice and the capability tags differ between rows — which
is what that UI was built for.

An interrupted 2 GB upload starts over. If that becomes a real complaint, the
answer is a provider-specific chunked extension behind the same interface, and
this ADR is where to record it.
