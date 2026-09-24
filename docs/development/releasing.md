# Releasing

A version tag builds both platforms and leaves a **draft** GitHub Release
(`.github/workflows/release.yml`): `relay-<version>-macos.dmg`,
`relay-<version>-windows-x64.zip` (the `Relay` folder with the Visual C++ runtime beside
`relay.exe`) and `SHA256SUMS.txt`. The README's *Install* section is written against those names.

1. `main` is green in CI.
2. Tag and push. The tag is the version; `pubspec.yaml` needs no bump. Until *Release readiness*
   in [`testing.md`](testing.md) passes, use a hyphenated tag — that makes a pre-release:

   ```bash
   git tag v0.5.0-beta.1
   git push origin v0.5.0-beta.1
   ```

3. When the **Release** workflow finishes, open the draft on the Releases page, check it, and
   press **Publish release**.

**Replace the macOS DMG before publishing, if you can.** The runner has no certificate and signs
ad-hoc, so users re-grant screen recording after every update (`tccutil reset ScreenCapture
com.relay.relay`, then allow again). A DMG signed with the project's Apple Development
certificate keeps the grant ([`macos-tcc-and-launchservices.md`](macos-tcc-and-launchservices.md)):

```bash
git checkout v0.5.0-beta.1
flutter build macos --release --build-name=0.5.0-beta.1
./tool/package-dmg.sh --out build/relay-0.5.0-beta.1-macos.dmg
shasum -a 256 build/relay-0.5.0-beta.1-macos.dmg   # update its line in SHA256SUMS.txt
```

Upload it over the draft's asset with the same name. Neither signature opens with a double click
— that needs Developer ID and notarization (`tool/package-dmg.sh --sign … --notarize …`). Windows
has no Authenticode signing, so SmartScreen asks once.

A failed build leaves no draft. Fix it, move the tag (`git tag -f <tag> <commit> && git push -f
origin <tag>`) — only while nothing is published under it.
