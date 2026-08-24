# Upload Architecture

## Common abstraction

Uploads are replaceable destinations.

```text
UploadDestination
├── Telegram          no setup at all, 50 MB per file
├── WebDAV            an app password, no size limit of its own
└── future destinations
```

Google Drive was implemented and then removed — the reasoning is in
`../adr/2026-08-23-telegram-only-destination.md`. Nothing generic went with it:
the contracts below are what made removing one destination a deletion rather
than a refactor.

Recorder code must not know Telegram- or Google-specific APIs.

Conceptual responsibilities:

```text
describe how it is connected   → DestinationSetup
report whether it is connected
connect / disconnect
validate(file)
authenticate if needed
upload(file)
report progress
cancel
retry/resume where supported
return typed remote result
```

## Shared transfer loop

`RetryingUploadDestination` in `upload_core` owns everything a transfer does
that is not protocol-specific: the stream controller, the `onListen`/`onCancel`
wiring, the pre-flight, the missing-file check, the attempt loop, the retry
backoff and the exactly-one-terminal-event guarantee.

A destination supplies `attempt()` and `unexpectedFailure()`, and may override
`retryRestartsProgress`. Nothing else.

This used to exist twice, once per destination, in two ~250-line copies — and
they had already drifted: Telegram emitted `UploadValidating` and validated the
file a second time, WebDAV did neither. **Pre-flight ownership is now settled:**
the destination validates, because it is the only party that knows its own
limits and `upload()` has to be safe to call directly; the coordinator's own
`validate` call is what reports a rejection to the user before any bytes move,
and it emits the single `UploadValidating` event.

The primitives the loop is built from — `UploadJob`, `TransferDeadline`,
`countingStream`, `AttemptOutcome`, `UploadAborted` — are exported so a
destination's `attempt()` uses the same cancellation and stall semantics as
every other one.

`UploadDestination.dispose()` is part of the contract, so the registry can
release every destination it owns without knowing what any of them are. Both
shipping implementations had this method before the contract did, which meant
nothing could reach it.

## Connection

A destination describes its own setup; no screen knows a destination by name.

```text
DestinationSetup
├── kind          credentials | interactive
├── actionLabel   "Connect" / "Sign in with Google"
├── steps         ordered, plain language, shown in the connect screen
└── fields        DestinationField(key, label, hint, secret, optional)
```

`ConnectDestinationScreen` renders that description and calls
`connect(values)`. Rules that hold for every destination:

- **verify, then store.** A destination checks credentials with its service
  inside `connect` and throws a typed `UploadError` when they are refused. The
  screen shows that message. Nothing reaches storage until it has been proven.
- **secrets are write-only.** A `secret` field is never returned from
  `storedSetupValues`, is masked as it is typed, and is cleared after a
  successful connect. An empty submission means "keep the stored value".
- **`.env` is a seed, not a store.** A deployment may preconfigure a build; a
  connection made in the application takes precedence, and a disconnect is not
  undone by the seed on the next launch.
- **credentials live in `CredentialStore`** — the macOS Keychain, the Windows
  Credential Manager — never in a file beside the binary.

macOS has two keychains, and which one a build may use depends on how it was
signed. The **data-protection** keychain needs the `keychain-access-groups`
entitlement, which needs a provisioning profile this project does not carry; a
build without it does
not have it, and every write fails with `errSecMissingEntitlement` (-34018).
`SecureCredentialStore` chooses between that keychain and the **file-based login
keychain** — which has no such requirement and is still the macOS Keychain — by a
**memoized sentinel write**: it writes and deletes `SecureCredentialStore.probeKey`
once, before anything else, and `-34018` selects the login keychain for the rest of
the process.

It is a probe and not a caught failure because **the decision cannot be inferred
from a read**. A read against the data-protection keychain from a process with no
access group does not fail; it returns empty (`errSecItemNotFound`), which the
plugin reports as "no value". Since every launch begins by reading, inferring from
failure meant the fallback only engaged *after* a destination was connected in that
same process — the symptom was "it forgets my WebDAV every time I rebuild".

`read` falls back across keychains; `delete` hits **both**. A properly signed build
keeps the better keychain; a development build stores its credentials instead of
refusing to.

See `docs/adr/2026-08-23-destination-credentials-in-app.md`.

## Coordinator

A common upload coordinator owns:

- selected destination;
- common upload state;
- local-file handoff;
- common error mapping;
- success → local deletion policy.

Destination implementation owns provider-specific validation, auth and transport.

## Progress semantics

`UploadProgress.bytesSent` is what the destination can account for, and its
meaning follows the destination's capabilities:

| Destination kind | What progress means |
|---|---|
| resumable (`supportsResume: true`) | the offset the server acknowledged |
| single-shot | bytes written to the request body |

**No shipping destination is the first kind** — Telegram and WebDAV both declare
`supportsResume: false`. The table is the contract a resumable destination would
have to satisfy, not a description of today.

Both shipping destinations are single-shot: Telegram sends one multipart POST and
WebDAV one streaming PUT, neither of which offers an intermediate acknowledgement,
so both report what they have read out of the file.

This does not weaken §18. Progress is a display value; **local deletion follows
the terminal `UploadSucceeded` event and nothing else**, which is why the
coordinator and the recorder feature are separate and why deletion requires a
stated `DeletionReason`.

## Common safety rules

- validate before starting;
- surface network/auth/provider errors as typed domain errors;
- support cancellation;
- never delete local file before confirmed remote success;
- upload failure/cancellation preserves local media.

## Telegram

Connected in Settings: bot token, chat id, optional Bot API base URL. The token
goes to the OS credential store; `getMe` and `getChat` are called first, so a
bad token or an unreachable chat is reported at setup.

A deployment may seed a build with:

```text
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
TELEGRAM_BOT_API_BASE_URL
```

Never commit real credentials.

A bot token bundled in a public desktop binary or `.env` is not a secret.

The standard hosted Bot API has a hard upload-size limit; perform file-size preflight and fail fast rather than starting an impossible upload.

Keep the Bot API base URL configurable to allow a future Local Bot API Server.

If the application becomes public, revisit the trust model; a backend/proxy or different authorization model may be required.

## Lifting Telegram's size cap

The hosted Bot API refuses a video over 50 MB, which a 1080p recording passes in
about three minutes. The answer is Telegram's own Local Bot API Server, run by
the user: 2000 MB, free, and the destination already treats its base URL as
configuration, so nothing in the transport changes.

`TelegramConfig.maxUploadBytes` returns null for a non-hosted endpoint, which is
what makes the `50 MB max` tag disappear from the UI and the pre-flight stop
refusing large files — with no UI change (§16, §28).

Relay does not install, launch or supervise that server. It documents it
(README), and the base-URL field links to Telegram's description of it.

## WebDAV

A protocol, not a service: one implementation reaches Koofr, any Nextcloud or
ownCloud, Box and others. Changing provider is a different URL in a text field.

- **Auth** is HTTP Basic with an app password from the provider's own account
  settings. No OAuth, no client id, nothing that expires. The password goes to
  the OS credential store (§27) and travels in a header, never in a URL.
- **Connect** proves the account before storing: `PROPFIND` for the credentials,
  `MKCOL` for the folder. A wrong address, a rejected password or a read-only
  account is reported at setup.
- **Transfer** is one streaming `PUT`. The file is read as it is sent, so memory
  does not grow with the recording.
- **No resume**, and `supportsResume` says so: WebDAV has no standard way to
  continue a partial `PUT`. Retries restart the transfer; the local file is
  preserved either way (§13).

Koofr is the documented provider — 10 GB free, WebDAV on the free plan. Nothing
in the package is Koofr-specific; it appears in setup steps and field hints
only. Yandex.Disk is deliberately not suggested: its WebDAV is throttled to
roughly a minute per megabyte. See
`../adr/2026-08-23-webdav-second-destination.md`.

## Future destinations

Adding S3/OneDrive/etc. should normally require:

- new `UploadDestination` implementation, including its `DestinationSetup`;
- dependency registration;
- tests.

The reverse is the same shape: removing Google Drive was deleting a package, one
registration and a settings migration.

It should **not** require a new settings or auth screen: the connect screen
renders whatever the destination declares.

It should not require recorder changes.
