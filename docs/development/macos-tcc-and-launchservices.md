# macOS TCC and LaunchServices

**Status:** Accepted — the rebuild question was settled by measurement on 2026-08-25
**Scope:** diagnosing screen-recording, microphone and camera permission on macOS during development
**Review when:** the signing identity changes, or `tool/install.sh` / `tool/reset-permissions.sh` change

Everything here was learned by hand and lived only in `tool/install.sh` comments and its
closing `printf` block. It is collected here because an agent debugging a permission
failure reads `docs/`, not a 380-line shell script.

---

## Launch the app with `open`, and with a full path

```bash
open /Applications/relay.app      # correct
```

Not the binary inside the bundle, and not `open -a relay`.

macOS attributes a privacy request to the **responsible process**. A binary `exec`'d from a
shell is judged as that shell — which holds no screen-recording grant — and Relay then
enumerates zero sources. `open -a relay` resolves the name through LaunchServices and may
pick a build-tree copy instead of the installed one.

This applies to `./run-relay.sh` and to `flutter run`: both are attributed to the calling
terminal. `docs/adr/2026-08-24-screen-recording-permission-applies-on-relaunch.md` records
how the app detects and reports this.

A granted answer also only takes effect at the **next** start. Grant, then relaunch.

---

## Does a rebuild invalidate the grant?

**It depends on how the build is signed, which is why the repository used to say both.**
Verified on this host, 2026-08-25:

| Signing | Designated requirement | Grant across rebuilds |
|---|---|---|
| `Apple Development` / `Developer ID` | `identifier "com.relay.relay" and anchor apple generic and certificate leaf[subject.CN] = "…"` | **Survives.** The requirement names the identifier and the certificate, not the code. |
| ad-hoc (`CODE_SIGN_IDENTITY = -`) | `cdhash H"db65…"` | **Lost every build.** The requirement names the code itself, which changes on every compile. |

TCC stores the designated requirement, not a `cdhash`, so with a real identity the Debug
and Release bundles here have *different* `CDHash` values and the *same* designated
requirement — and both satisfy a grant given to either.

Check which case you are in:

```bash
codesign -d -r- build/macos/Build/Products/Debug/relay.app
```

`macos/Runner/Configs/Signing.xcconfig` selects the identity, overridable per machine via
a git-ignored `Signing.local.xcconfig`.

### So when is `tool/reset-permissions.sh` the right answer?

Only when the build is **ad-hoc signed**. With a real identity it deletes a working grant
and buys nothing.

A denial on an identity-signed build is almost always the launch method, not the
signature. Diagnose with the log query below before resetting anything.

---

## Reading the TCC log without being misled

```bash
/usr/bin/log show --last 15m --predicate 'subsystem == "com.apple.TCC"' \
  --info --debug | grep AUTHREQ_ATTRIBUTION | grep com.relay.relay
```

Three traps, each of which makes a working system look broken:

1. **Use the absolute `/usr/bin/log`.** Some shells carry a `log` function or alias that
   shadows it, answers *"too many arguments"*, and returns nothing — which reads as
   *no TCC records exist*.
2. **Grep the attribution line, not the result line.** `tccd` splits one request across
   three lines joined by `msgID`: `AUTHREQ_CTX` carries the service, `AUTHREQ_ATTRIBUTION`
   the client and the responsible process, `AUTHREQ_RESULT` the `authValue`. Only the
   attribution line names the app, so grepping results for `relay` matches nothing.
3. **Read the `responsible=` field.** A line with no `responsible=` is the app answering
   for itself, which is what a grant needs. A line naming another process is the launch
   method being wrong.

---

## LaunchServices

- `lsregister` is private and undocumented, and its flags change. `-kill` was removed in
  macOS 26. **`-domain` never existed at all** — it is a silent no-op that exits `0` and
  therefore reads as success. Only `-f`, `-u` and `-dump` are used by `tool/install.sh`.
- A copy in `/Applications` outranks any build-tree copy regardless of version. Leftover
  registrations are hygiene; a record whose bundle is gone is residue, and only
  `lsregister -u <path>` clears it.
- Installing anywhere other than `/Applications` is unsupported: LaunchServices and TCC
  resolve `com.relay.relay` by whichever copy they rank first. `RELAY_INSTALL_DIR` exists
  to exercise the install script against a scratch directory, not to run from one.

---

## Detecting a running copy

Never `pgrep -f relay`. This repository lives in a directory called `Relay`, so the pattern
matches the searching shell itself. `tool/install.sh` uses `pgrep -x relay` and then
`ps -o comm=` to confirm the executable path ends in `/relay.app/Contents/MacOS/relay`.

---

## Related

- `docs/development/compatibility-matrix.md` — what is verified on which host
- `docs/adr/2026-08-24-screen-recording-permission-applies-on-relaunch.md`
- `docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md` — a denied mic or
  camera degrades the session instead of blocking it
- `tool/install.sh`, `tool/reset-permissions.sh`
