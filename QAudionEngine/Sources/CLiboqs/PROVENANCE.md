# CLiboqs — provenance and integrity

## What this is

A hand-vendored subset of `open-quantum-safe/liboqs`, specifically the
`mlkem-native` reference C implementation of ML-KEM-1024 (FIPS 203), plus a
portable XKCP Keccak-based SHA3/SHAKE implementation and a thin `OQS_KEM`
API wrapper. Vendored in as a local SwiftPM source target (`Package.swift`,
`.target(name: "CLiboqs", path: "Sources/CLiboqs")`) rather than pulled in
as a git dependency, because upstream liboqs' full build requires CMake and
optionally OpenSSL, neither of which fit a standalone SwiftPM build.

## Known facts

- Vendored by commit `ae6e8b5` (2026-04-08), "feat(crypto+audio): replace
  stubs with real liboqs ML-KEM-1024 and libopus sources", which replaced an
  earlier `oqs_stub.c` placeholder.
- The commit message names the upstream source as
  `open-quantum-safe/liboqs` (mlkem-native reference C code, FIPS 203) but
  did **not** record the specific upstream commit/tag it was vendored from.
  That exact upstream reference is not recoverable with confidence after
  the fact — do not invent one.
- `include/oqs/oqsconfig.h` carries a custom relabeled version string
  (`OQS_VERSION_TEXT "0.12.0-qaudion"`) rather than an upstream liboqs
  release tag, which is consistent with this being a hand-assembled subset,
  not a full upstream checkout.

## What this means for the FIPS/MASVS self-assessment

`SECURITY.md`'s prior claim of a "pinned commit SHA...verified in CI" for
liboqs did not match this reality and has been corrected (see
`docs/security/FIPS_PQC_CONFORMANCE_2026-08-21.md` in `qaudion-android-new`
for the full finding). There is no upstream git pin to verify against. What
*is* verifiable and enforced going forward is **local integrity**: that this
vendored source tree doesn't silently change between the point this note
was written and any future point in time.

## Integrity checkpoint

SHA-256 over the sorted `sha256sum` manifest of every file under this
directory, computed 2026-08-21:

```
e1d7c31783a6dfc2d11e38c82fdc5ac0420eddb893cb7cfee103314ce5df0090
```

To recompute and compare:

```bash
cd QAudionEngine/Sources/CLiboqs
find . -type f | sort | xargs sha256sum > /tmp/cliboqs_manifest.txt
sha256sum /tmp/cliboqs_manifest.txt | awk '{print $1}'
```

If this hash ever changes, it means either a legitimate deliberate edit (in
which case update this file with the new hash and a note explaining the
change) or an unexpected/unauthorized modification worth investigating
before merging. This is a manual checkpoint today; if a real CI-enforced
gate is wanted, wire the same two commands into a workflow step that fails
the build on mismatch (not yet done — flagged as a follow-up, not silently
assumed to already exist).
