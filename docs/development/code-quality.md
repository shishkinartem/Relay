# Code Quality, Scalability and Reliability

## Principle

Design for known extension points without creating speculative enterprise abstractions.

Create an abstraction when at least one is true:

- multiple implementations exist;
- a platform/external-service boundary exists;
- tests need a meaningful substitute;
- the product explicitly expects another implementation;
- dependency inversion is required.

## Enforced, not just stated

`test/architecture_test.dart` runs on every `flutter test` and checks six of the rules
below against the source. Breaking one is a failing test, not a review comment:

1. no `Platform.isMacOS` / `isWindows` / `isLinux` / `operatingSystem` anywhere in `lib/`,
   including the composition root;
2. no plugin package imported outside `lib/app/composition_root.dart`;
3. `dart:io` only from the six files in the test's allowlist;
4. `lib/design_system/` never references `features/`;
5. no Flutter widget imports in any `/domain/` file;
6. every collaborator an `/application/` class holds is an interface, not a concrete type.

Both allowlists — the `dart:io` file list and the substitutability `values` set — are
meant to be extended, by name and with a stated reason in the change that adds it.
Weakening a rule should cost more than satisfying it.

## Modularity

Keep dependencies acyclic.

Avoid catch-all `utils`, `helpers`, `common`, or god-service modules.

Prefer cohesive domain-oriented modules with explicit responsibilities.

## Stable contracts

Treat Flutter/native boundaries and persisted schemas as contracts.

For platform APIs define:

- inputs;
- outputs;
- typed errors;
- lifecycle;
- cancellation;
- ownership;
- compatibility.

Prefer additive evolution.

When the contract changes, update all supported platform implementations and their tests.

## Settings/data migrations

Persisted settings are versioned data.

Use a schema version.

When changing schema:

- add deterministic migrations;
- test migration from previously shipped versions;
- preserve recoverable settings;
- version pending-upload/recovery metadata when persisted.

## Resource ownership

Every long-lived resource has one clear owner.

Examples:

- capture stream;
- camera;
- microphone/system-audio session;
- compositor;
- encoder;
- muxer;
- output file;
- resumable upload;
- OAuth session.

Cleanup must be deterministic and safe on error/cancellation.

## Idempotency

Lifecycle/destructive commands must be idempotent or explicitly guarded.

Repeated calls must not cause:

- corrupt files;
- duplicate uploads;
- contradictory states;
- native crashes;
- unsafe deletion.

## Security

- no secrets in source control;
- `.env` is ignored; `.env.example` may be committed;
- never log bot/OAuth tokens or authorization codes;
- store user OAuth credentials in OS secure storage;
- request least-privilege OAuth scopes;
- do not treat client-side obfuscation as secret storage;
- review native/binary dependencies for supply-chain impact.

## Logging/diagnostics

Use structured logs/metrics.

Useful non-content signals include:

```text
recording_duration
input_frame_rate
encoded_frame_rate
dropped_frames
audio_discontinuities
av_drift_ms
encoder_name
hardware_encoding_used
finalization_duration
upload_bytes
upload_retries
upload_resume_count
```

Never automatically attach raw screen/audio/camera content to diagnostics.

## Dependency policy

Before adding a dependency, check:

1. whether standard Flutter/Dart/native APIs already solve the problem;
2. maintenance/activity;
3. license;
4. desktop support;
5. native binary footprint;
6. transitive native dependencies;
7. packaging impact.

Do not add a dependency for trivial helpers.

Avoid unrelated dependency upgrades in feature patches.

## Change discipline

Keep changes focused.

Do not mix broad formatting/refactoring with sensitive media changes unless required.

Before finalizing:

- inspect the diff;
- verify no credentials/generated junk were added;
- run required tests;
- report what was actually tested;
- document known gaps.

## Compatibility matrix

Maintain a checked-in support matrix before release:

```text
Platform | Minimum version | Display capture | Window capture | System audio | Camera | 30 FPS | 60 FPS
```

"Supported" means build + basic flow tested, not merely compilable.

## Feature flags

Temporary feature flags may help safely roll out high-risk changes:

- new encoder;
- new capture backend;
- new compositor;
- 120 FPS;
- Linux beta;
- new resumable-upload implementation.

Every flag needs a purpose and removal condition. Do not let flags become permanent parallel architecture by accident.
