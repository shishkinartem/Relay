# macOS TCC and LaunchServices

**Status:** Accepted — the rebuild question was settled by measurement on 2026-08-25
**Scope:** diagnosing screen-recording, microphone and camera permission on macOS during development
**Review when:** the signing identity changes, or `tool/reset-permissions.sh` changes

Collected here because an agent debugging a permission failure reads `docs/`, not a
380-line shell script.

Provenance matters for this file. Most of it originated as commentary in an install
script that had never actually been run, so its claims carried no field experience — two
of the original four did not survive checking. Everything below was re-verified directly
against macOS 26.5 on 2026-08-25, and the script itself has since been deleted. Do not
add anything here that you have not run.

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

**Grep the attribution line, not the result line.** `tccd` splits one request across
three record types. Measured over six hours on this host: `AUTHREQ_CTX` 5501,
`AUTHREQ_ATTRIBUTION` 5499, `AUTHREQ_RESULT` 5499. `CTX` carries the service, `RESULT`
the `authValue`, and only `ATTRIBUTION` names the client — so grepping the result lines
for `relay` matches nothing and reads, wrongly, as *no records exist*.

**Read the `responsible=` field.** It is present on a minority of attribution lines — 187
of 5516 here — and its absence is the normal case: no `responsible=` means the app is
answering for itself, which is what a grant needs. A line naming another process is the
launch method being wrong. Attribution lines otherwise always carry `pid=`,
`identifier=`, `binary_path=`, `euid=` and `auid=`.

Using the absolute `/usr/bin/log` costs nothing and avoids any shell that defines its own
`log`. (The original note claimed this repository's shell does; it does not — `log`
resolves to `/usr/bin/log` here.)

---

## LaunchServices

- `lsregister` is private and undocumented, and its flags change. **Verified** against
  `lsregister -h` on macOS 26.5: the documented options are `-delete -seed -lint -lazy
  -r -R -f -u -v -gc -dump -h`. There is **no `-domain` flag** — "domain" exists only as
  an argument to `-apps`, `-libs` and `-all` (`system`, `local`, `network`, `user`), so
  `-domain something` is not an option and must not be relied on. `-kill` is likewise
  absent. Prefer `-f`, `-u` and `-dump`; treat anything else as version-dependent.
- A copy in `/Applications` outranks any build-tree copy regardless of version. Leftover
  registrations are hygiene; a record whose bundle is gone is residue, and only
  `lsregister -u <path>` clears it.
- Installing anywhere other than `/Applications` is unsupported: LaunchServices and TCC
  resolve `com.relay.relay` by whichever copy they rank first. `RELAY_INSTALL_DIR` exists
  to exercise the install script against a scratch directory, not to run from one.

---

## Detecting a running copy

Use `pgrep -x relay`, then `ps -o comm=` to confirm the executable path ends in
`/relay.app/Contents/MacOS/relay`.

`pgrep -f` matches whole command lines, and **measured here** `pgrep -fl Relay` returns
`/usr/libexec/SidecarRelay` and every shell whose command line contains this repository's
path — neither of which is the app. (`pgrep -f relay`, lower-case, matches nothing at
all: the directory is `Relay` and the match is case-sensitive — so the commonly given
reason for avoiding `-f` here is itself wrong, even though `-x` is still the right
choice.)

---

## Related

- `docs/development/compatibility-matrix.md` — what is verified on which host
- `docs/adr/2026-08-24-screen-recording-permission-applies-on-relaunch.md`
- `docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md` — a denied mic or
  camera degrades the session instead of blocking it
- `tool/reset-permissions.sh`
