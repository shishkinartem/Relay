# Releasing

**Status:** Current
**Scope:** turning a commit on `main` into a published GitHub Release
**Review when:** `.github/workflows/release.yml` changes, or the project gets a Developer ID or
an Authenticode certificate

A release is a version tag. Pushing one runs `.github/workflows/release.yml`, which builds both
platforms from that commit and leaves a **draft** release on the Releases page with three
assets:

| Asset | What it is |
|---|---|
| `relay-<version>-macos.dmg` | the macOS app, **ad-hoc signed** — the runner has no Apple certificate |
| `relay-<version>-windows-x64.zip` | a `Relay` folder: `relay.exe`, its DLLs, `data\`, and the Visual C++ runtime DLLs beside them |
| `SHA256SUMS.txt` | checksums of the two above |

Nothing is public until the draft is published. [`../install.md`](../install.md) is written
against exactly these asset names, and the release notes link to it.

## Cutting one

1. `main` is green in CI, and the compatibility matrix says what this build has and has not been
   run on.
2. Tag the commit and push the tag. The tag is the version — both builds are stamped with it —
   so `pubspec.yaml`'s version does not need a bump first.

   A hyphen makes a **pre-release**, and until everything under *Release readiness* in
   [`testing.md`](testing.md) passes — Windows integration and the soak tests among it — every
   release is one. That is what the Releases page should say about a build that is still in
   testing, and it keeps the plain `v0.5.0` for the build that is not:

   ```bash
   git tag v0.5.0-beta.1
   git push origin v0.5.0-beta.1
   ```

   GitHub's `/releases/latest` never points at a pre-release, which is why `../install.md` and
   the README send people to the Releases page itself.

3. Wait for the **Release** workflow in the Actions tab. It takes about as long as CI.
4. Open the draft on the Releases page, read the generated notes, and optionally replace the
   macOS DMG (below). Then **Publish release**.

A failed build leaves no draft behind. Fix the cause, then move the tag to the fixed commit and
push it again (`git tag -f v0.5.0-beta.1 <commit> && git push -f origin v0.5.0-beta.1`) — which
is only safe while nothing has been published under that tag.

## The macOS DMG is worth replacing

The runner signs ad-hoc, and macOS keys the screen-recording permission of an ad-hoc app to that
exact build. Every user who updates to the next release therefore grants screen recording again
— `../install.md` tells them how, but it is friction the project can avoid.

A DMG built on a Mac with the project's **Apple Development** certificate keeps the grant across
updates, because its designated requirement names the certificate rather than the code
([`macos-tcc-and-launchservices.md`](macos-tcc-and-launchservices.md)). Build one from the same
tag and upload it over the draft's asset, with the same name:

```bash
git checkout v0.5.0-beta.1
flutter build macos --release --build-name=0.5.0-beta.1
./tool/package-dmg.sh --out build/relay-0.5.0-beta.1-macos.dmg
shasum -a 256 build/relay-0.5.0-beta.1-macos.dmg
```

Then update its line in `SHA256SUMS.txt` to match. Either signature still needs the user to clear
the quarantine flag: only **Developer ID + notarization** opens with a double click, and that
needs a paid Apple Developer Program membership (`tool/package-dmg.sh --sign … --notarize …`).

## Windows signing

There is none. SmartScreen asks once per downloaded `relay.exe` — **More info → Run anyway** —
and says *unknown publisher*. An Authenticode certificate would remove that; nothing in the
workflow is prepared for one yet.
