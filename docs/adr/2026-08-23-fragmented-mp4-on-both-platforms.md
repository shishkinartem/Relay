# Both platforms write fragmented MP4

**Status:** Accepted
**Date:** 2026-08-23

## Context

`TECHNICAL_SPEC.md` §18 and `docs/architecture/recording.md` require that a
recording interrupted by a crash, a forced quit or an explicit abort leaves a
`recording-<id>.part` artefact on disk which startup recovery can read and
finalize. Nothing is silently discarded.

macOS already satisfies that. `RecordingSession.swift` sets

```swift
writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
```

so the file on disk stays readable up to the last flushed fragment even if the
process never reaches `finishWriting()`.

Windows did not. `media_writer.cpp` configured the sink writer with

```cpp
attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
```

Plain `MPEG4` writes the `moov` atom only in `IMFSinkWriter::Finalize()`, and
`RecordingSession::Abort()` deliberately does not call it — the comment there
says so: *"No Finalize and no delete: the `.part` artefact stays on disk for
startup recovery (spec 18)."* Recovery then goes through `MediaWriter::Probe`,
which needs `MFCreateSourceReaderFromURL` to parse the file and a
`duration_ms > 0`. Neither is obtainable without a `moov`.

The result was a guarantee that held on one platform out of two, and **Dart
could not see the difference**: both platforms answer the same
`recoverArtifact` call, one with a file and one with `null`. No test on either
side could catch it, because there is no Windows build and the platform
integration suite does not run.

## Decision

Both platforms write **fragmented MP4**. On Windows the container type becomes

```cpp
attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_FMPEG4);
```

which is the Media Foundation equivalent of what `movieFragmentInterval`
already does on macOS: periodic self-contained `moof`/`mdat` fragments, so a
truncated file is readable up to the last one.

The container, codec and extension are unchanged — MP4 / H.264 / AAC, written
to `recording-<id>.part` and renamed to `.mp4`. Fragmentation is a structural
property *inside* the MP4 container, not a different container.

## Consequences

- The §18 recovery guarantee becomes true on both platforms rather than one.
  `MediaWriter::Probe` can parse an aborted artefact because each fragment
  carries its own index.
- Files are marginally larger: fragment headers repeat per interval. At the
  bitrates in §12 this is well under one percent.
- Fragmented MP4 is read by every current player, by QuickTime, by browsers and
  by `MFCreateSourceReaderFromURL`. Some older editing tools prefer a single
  `moov`; if that ever becomes a real complaint, the answer is a post-finalize
  remux, not giving up recovery.
- The alternative — dropping fragmentation on macOS so the two platforms match
  — was rejected. It makes both platforms unrecoverable and deletes a
  guarantee the specification requires.

## Validation

```text
NOT RUN: Windows native build and playback verification
Reason: no MSVC toolchain, no Windows SDK and no cmake on the development host
```

The change is one attribute GUID and is not covered by any executing test. It
must be compiled and a recording aborted mid-session must be confirmed
recoverable before this ADR moves past first release. `docs/development/
compatibility-matrix.md` carries the same NOT RUN entry.
