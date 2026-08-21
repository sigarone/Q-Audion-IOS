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
- `include/oqs/oqsconfig.h` carries a custom relabeled version string
  (`OQS_VERSION_TEXT "0.12.0-qaudion"`) rather than an upstream liboqs
  release tag, which is consistent with this being a hand-assembled subset,
  not a full upstream checkout.

## Upstream provenance — identified 2026-08-21 by direct comparison

The exact upstream commit was not recorded at vendoring time, but it *is*
recoverable: the vendored source was diffed file-by-file against the real
upstream projects (shallow git clones, `diff -rq`), not guessed from
comments or file names.

**ML-KEM core (`src/mlkem/*.c`, `*.h`, `zetas.inc` — 22 files checked)** is
byte-for-byte identical to
[`pq-code-package/mlkem-native`](https://github.com/pq-code-package/mlkem-native)
tag `v1.1.0`, commit `d2cae2be522a67bfae26100fdb520576f1b2ef90`:
`kem.c`, `kem.h`, `indcpa.c`, `indcpa.h`, `poly.c`, `poly.h`, `poly_k.c`,
`poly_k.h`, `compress.c`, `compress.h`, `sampling.c`, `sampling.h`,
`verify.c`, `verify.h`, `params.h`, `common.h`, `symmetric.h`,
`randombytes.h`, `sys.h`, `cbmc.h`, `debug.c`, `zetas.inc` — every one an
exact match, confirmed via `diff -q` against a fresh clone of the tag. The
newer `v1.2.0`/`v1.3.0` tags do NOT match (same algorithm, but a later
Doxygen-style doc-comment rewrite and added CBMC loop-termination
annotations diverge) — `v1.1.0` is the correct pin, not just "close enough".
The files present upstream but absent here (the `native/` optimized
SIMD backends for aarch64/x86_64/riscv64, and the `fips202/` module) are
expected: this vendoring kept only the portable reference C build and
supplied its own FIPS202/Keccak backend instead (below), wired through
mlkem-native's own supported customization hooks
(`MLK_CONFIG_FIPS202_CUSTOM_HEADER` etc. in `mlkem_native_config.h`) — a
documented, intended integration path, not a hack.

**Keccak/SHA3 core
(`src/common/sha3/xkcp_low/KeccakP-1600/plain-64bits/*`, 7 files)** is
byte-for-byte identical to the same `xkcp_low` tree currently vendored
inside [`open-quantum-safe/liboqs`](https://github.com/open-quantum-safe/liboqs)
itself (checked against liboqs's live `main` branch 2026-08-21 — this is
liboqs's own re-vendoring of XKCP's `KeccakP-1600` permutation, not raw
`XKCP/XKCP`, which has since reorganized its directory layout and no longer
matches directly): `brg_endian.h`, `KeccakP-1600-64.macros`,
`KeccakP-1600-opt64-config.h`, `KeccakP-1600-opt64.c`, `KeccakP-1600-SnP.h`,
`KeccakP-1600-unrolling.macros`, `SnP-Relaned.h`. Only `xkcp_sha3.c` (the
higher-level API wrapper) differs — expected, since its own header
explicitly says it was hand-"adapted from liboqs... for Q-Audion iOS
standalone SPM build" (no CMake-based backend dispatch needed here).

To reproduce this check:

```bash
git clone --depth 1 --branch v1.1.0 https://github.com/pq-code-package/mlkem-native.git /tmp/mlkem-native-v1.1.0
diff -rq QAudionEngine/Sources/CLiboqs/src/mlkem /tmp/mlkem-native-v1.1.0/mlkem/src
# expect: only "Only in .../mlkem: mlkem_fips202_glue.h / mlkem_fips202x4_glue.h /
# mlkem_native_config.h" and "Only in .../mlkem-native.../src: fips202, native, meta.h"
# -- no line reporting two files of the same name that DIFFER.

git clone --depth 1 https://github.com/open-quantum-safe/liboqs.git /tmp/liboqs-upstream
diff -rq QAudionEngine/Sources/CLiboqs/src/common/sha3/xkcp_low/KeccakP-1600/plain-64bits \
         /tmp/liboqs-upstream/src/common/sha3/xkcp_low/KeccakP-1600/plain-64bits
# expect: no output (all 7 files identical)
```

## What this means for the FIPS/MASVS self-assessment

`SECURITY.md`'s prior claim of a "pinned commit SHA...verified in CI" for
liboqs did not match reality (there is still no git-level pin — this is a
local vendored source target, not a `.package(url:, revision:)`
dependency) and has been corrected (see
`docs/security/FIPS_PQC_CONFORMANCE_2026-08-21.md` in `qaudion-android-new`
for the full finding). What's true now, and wasn't before: the exact
upstream commit for the security-critical crypto core (ML-KEM + Keccak) is
identified and documented above, verified by direct byte-level comparison,
not asserted from a comment. Combined with the integrity checkpoint below,
this is real, checkable provenance — just delivered as a doc + manual
verification procedure instead of a Package.swift git pin, since the source
isn't structured as a git dependency.

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
