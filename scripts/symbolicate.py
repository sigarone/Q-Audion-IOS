#!/usr/bin/env python3
"""
P0-B — Symbolicate a stripped iOS crash stack to file:line WITHOUT a Mac.

The W417 telemetry (see CLAUDE.md sec 16, LiveLogStreamer.swift) ships
release crash backtraces in the live-log chunks. A release build is
stripped, so the device can only report the *image-relative offset* of
each frame, e.g.:

    [CrashReporter] 4   QAudionApp   0x000000010467a828 QAudionApp + 550952

plus the Swift assert line that fired the trap:

    fatal: /path/ChatDetailScreen.swift:145: Fatal error: ...

This script turns those offsets back into `file:line` by pairing them
with the matching dSYM that the TestFlight build produced.

ADDRESS MATH (arm64 Mach-O — the part you must get right)
---------------------------------------------------------
* The QAudionApp Mach-O is a PIE (position-independent executable). Its
  __TEXT segment vmaddr (the "preferred load address" baked into the
  dSYM's DWARF) is the classic arm64 value 0x100000000 (4 GiB).
* At runtime dyld slides the image to some random load address. The
  crash reporter already subtracted that load address, so the number
  after "QAudionApp + " is the *file offset within the image* (a.k.a.
  the slide-removed offset), NOT a runtime address.
* The DWARF line tables are keyed on the *static virtual address* =
  __TEXT vmaddr + offset. Therefore:

        static_addr = 0x100000000 + offset

  We feed `static_addr` to llvm-symbolizer / the `symbolic` lib, which
  looks it up in the dSYM's debug line program and returns file:line.

  (If the binary were ever linked with a non-default __TEXT vmaddr we'd
  read it from the dSYM; we auto-detect it below and fall back to
  0x100000000, which is correct for every standard iOS arm64 build.)

The hex address in the frame (0x000000010467a828) is the *runtime*
address (load addr + offset) and is useless without the slide — we
deliberately use the decimal "+ offset" field, which is slide-free.

dSYM ACQUISITION
----------------
The TestFlight workflow (.github/workflows/ios-testflight.yml) uploads
the dSYM in TWO artifacts (P0-A):
  * `dsyms-<version>`        — dedicated, versioned, 90-day retention
                               (step 11). Preferred: stable name, long-
                               lived, dSYM-only (no IPA).
  * `ios-build-<run_number>` — the 7-day build bundle (step 10), which
                               also contains the dSYM zip at path
                               `QAudionApp/build/ios/dsym/*.zip`. NOTE
                               the name uses run_NUMBER, not run_id.
We resolve a build *version* (e.g. 1.0.662) to its CI run (tag/branch
`v<version>`), download the dSYM artifact by name (trying `dsyms-<ver>`
first, then `ios-build-<run_number>`), and cache the extracted DWARF
under `<repo>/.cache/dsyms/<version>/`. If both named downloads miss we
fall back to pulling all of the run's artifacts.

USAGE
-----
  # Symbolicate a crash dump file, auto-detecting the version from the
  # dump (looks for "build 1.0.NNN" / "v1.0.NNN" in the text):
  python scripts/symbolicate.py --crash .cache/ios-logs/live-XXXX.log

  # Force a specific build version (downloads dsyms-<ver> on demand):
  python scripts/symbolicate.py --crash crash.txt --version 1.0.662

  # Symbolicate a bare list of offsets piped on stdin:
  echo "QAudionApp + 550952" | python scripts/symbolicate.py --version 1.0.662

  # Point at an already-extracted .dSYM (skip gh download entirely):
  python scripts/symbolicate.py --crash crash.txt --dsym path/to/QAudionApp.app.dSYM

Requirements
------------
  * gh CLI (authenticated; same `sigarone/Q-Audion-IOS` repo) — only
    needed when the dSYM isn't cached and --dsym isn't given.
  * EITHER  `pip install symbolic`  (preferred, pure offline, exact),
    OR the Android NDK llvm-symbolizer at
      D:/users/f10379a/DEV APP/sdk/android-sdk/ndk/<ver>/toolchains/
      llvm/prebuilt/windows-x86_64/bin/llvm-symbolizer.exe
    (auto-discovered; works on Mach-O dSYMs cross-platform).
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------
# Constants — match fetch-ios-live.py style (module-level config, no classes).
# --------------------------------------------------------------------------
REPO = os.environ.get("QAUDION_IOS_REPO", "sigarone/Q-Audion-IOS")
IMAGE_NAME = "QAudionApp"               # Mach-O image as it appears in frames
DEFAULT_TEXT_VMADDR = 0x100000000       # arm64 PIE __TEXT vmaddr (4 GiB)
WORKFLOW = "ios-testflight.yml"

# Where the CI artifact lands the dSYM, and how the artifact is named.
# (Verified against .github/workflows/ios-testflight.yml step 10:
#  name: ios-build-<run_number>, path: QAudionApp/build/ios/dsym/*.zip)
ARTIFACT_NAME_TMPL = "ios-build-{run}"

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent           # apps/qaudion-ios
CACHE_DIR = REPO_ROOT / ".cache" / "dsyms"

# NDK fallback symbolizer (Windows). Newest NDK first.
NDK_ROOT = Path("D:/users/f10379a/DEV APP/sdk/android-sdk/ndk")


# --------------------------------------------------------------------------
# Crash-dump parsing
# --------------------------------------------------------------------------

# Frame line, e.g.:
#   [CrashReporter] 4   QAudionApp   0x000000010467a828 QAudionApp + 550952
# We key off the slide-free "<IMAGE> + <decimal offset>" tail. The leading
# "[CrashReporter] <n>" and the runtime hex address are optional context.
_FRAME_RE = re.compile(
    r"(?P<idx>\d+)\s+"
    + re.escape(IMAGE_NAME)
    + r"\s+0x(?P<runtime>[0-9a-fA-F]+)\s+"
    + re.escape(IMAGE_NAME)
    + r"\s*\+\s*(?P<offset>\d+)"
)

# Looser form used on stdin / hand-pasted lines: "QAudionApp + 550952"
_BARE_OFFSET_RE = re.compile(
    re.escape(IMAGE_NAME) + r"\s*\+\s*(?P<offset>\d+)"
)

# The Swift assert that fired the trap:
#   fatal: /…/ChatDetailScreen.swift:145: Fatal error: Duplicate values…
_FATAL_RE = re.compile(
    r"fatal:\s*(?P<file>[^\s:][^:]*?):(?P<line>\d+):\s*(?P<msg>.*)$"
)

# Version, e.g. "build 1.0.662", "v1.0.662", "version 1.0.662".
# IMPORTANT: the app version is always 1.0.NNN (CLAUDE.md release scheme:
# `git tag v1.0.NNN`). We deliberately anchor on the 1.0.NNN shape so a
# dependency version in the dump (e.g. "onnxruntime 1.24.2", "liboqs
# 0.12.0") can NEVER be mistaken for the app version and resolve the
# wrong dSYM. If the dump ever carries a non-1.0.* app version, the
# operator must pass --version explicitly (see resolve_app_version()).
_APP_VERSION_RE = re.compile(r"\bv?(?P<ver>1\.0\.\d+)\b")
# Generic X.Y.Z token — used ONLY to warn the operator that *some*
# version-looking token exists but none matched the app's 1.0.NNN shape.
_ANY_VERSION_RE = re.compile(r"\b[vV]?(?P<ver>\d+\.\d+\.\d+)\b")


def parse_crash(text):
    """Return (frames, fatal, version_guess).

    frames: list of dicts {idx, runtime, offset} in source order.
    fatal:  dict {file, line, msg} or None.
    version_guess: first version-looking token, or None.
    """
    frames = []
    fatal = None
    version_guess = None

    for raw in text.splitlines():
        line = raw.rstrip("\n")

        m = _FRAME_RE.search(line)
        if m:
            frames.append({
                "idx": int(m.group("idx")),
                "runtime": int(m.group("runtime"), 16),
                "offset": int(m.group("offset")),
            })
            continue

        if fatal is None:
            mf = _FATAL_RE.search(line)
            if mf:
                fatal = {
                    "file": mf.group("file").strip(),
                    "line": int(mf.group("line")),
                    "msg": mf.group("msg").strip(),
                }

    # Bare offsets (stdin / pasted) if no full frames matched.
    if not frames:
        for raw in text.splitlines():
            m = _BARE_OFFSET_RE.search(raw)
            if m:
                frames.append({
                    "idx": len(frames),
                    "runtime": None,
                    "offset": int(m.group("offset")),
                })

    # Version auto-detect — anchored to the app's 1.0.NNN scheme so a
    # dependency version (onnxruntime 1.24.2, liboqs 0.12.0, …) is never
    # picked. Prefer a line that mentions build/version AND carries a
    # 1.0.NNN token; else the first 1.0.NNN token anywhere in the dump.
    for raw in text.splitlines():
        if re.search(r"\b(build|version|app[_-]?ver|qaudion)\b", raw, re.I):
            mv = _APP_VERSION_RE.search(raw)
            if mv:
                version_guess = mv.group("ver")
                break
    if version_guess is None:
        mv = _APP_VERSION_RE.search(text)
        if mv:
            version_guess = mv.group("ver")

    return frames, fatal, version_guess


# --------------------------------------------------------------------------
# dSYM acquisition: cache → gh run download → extract
# --------------------------------------------------------------------------

def _run(cmd, **kw):
    """Run a subprocess, return (rc, stdout, stderr). Never raises on rc!=0."""
    p = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", **kw
    )
    return p.returncode, p.stdout, p.stderr


def _find_dwarf_binary(root: Path):
    """Locate the QAudionApp DWARF binary inside an extracted .dSYM tree.

    Layout: <name>.dSYM/Contents/Resources/DWARF/QAudionApp
    """
    # Exact preferred path first.
    for d in root.rglob("*.dSYM"):
        cand = d / "Contents" / "Resources" / "DWARF" / IMAGE_NAME
        if cand.is_file():
            return cand
    # Fall back to any DWARF/<file> named like the image.
    for cand in root.rglob(f"DWARF/{IMAGE_NAME}"):
        if cand.is_file():
            return cand
    # Last resort: any file under a DWARF/ dir.
    for d in root.rglob("DWARF"):
        if d.is_dir():
            for f in d.iterdir():
                if f.is_file():
                    return f
    return None


def _cached_dwarf(version):
    vdir = CACHE_DIR / version
    if vdir.is_dir():
        return _find_dwarf_binary(vdir)
    return None


def _resolve_run(version):
    """Find the CI run for tag v<version>. Returns (run_id, run_number).

    run_id     = databaseId, used by `gh run download <id>`.
    run_number = the human run counter, used to build the artifact NAME
                 (the workflow names artifacts `ios-build-<run_number>`
                 AND, since P0-A, `dsyms-<version>`). run_number may be
                 None if the fallback path can't recover it — callers
                 must handle that.

    The release tag is `v<version>` (CLAUDE.md: `git tag v1.0.NNN`), and
    `gh run list` reports it as headBranch on the run.
    """
    tag = f"v{version}"
    rc, out, err = _run([
        "gh", "run", "list", "--repo", REPO,
        "--workflow", WORKFLOW, "--branch", tag,
        "--limit", "10",
        "--json", "databaseId,number,headBranch,status,conclusion,displayTitle",
    ])
    if rc != 0:
        raise RuntimeError(f"gh run list failed: {err.strip() or out.strip()}")
    import json
    runs = json.loads(out or "[]")
    if not runs:
        # Fallback: search by displayTitle containing the version (the
        # bump commit is titled "chore: bump version to <version>").
        rc, out, err = _run([
            "gh", "run", "list", "--repo", REPO,
            "--workflow", WORKFLOW, "--limit", "60",
            "--json", "databaseId,number,headBranch,displayTitle",
        ])
        if rc == 0:
            for r in json.loads(out or "[]"):
                if version in (r.get("displayTitle") or "") \
                   or r.get("headBranch") == tag:
                    return r["databaseId"], r.get("number")
        raise RuntimeError(
            f"No CI run found for tag {tag}. "
            f"Pass --dsym to use a local dSYM, or check the version."
        )
    # Prefer a completed/successful run; else the most recent.
    runs.sort(key=lambda r: (r.get("conclusion") == "success"), reverse=True)
    return runs[0]["databaseId"], runs[0].get("number")


def _safe_extract_all(zf: zipfile.ZipFile, dest: Path):
    """Extract a zip with a zip-slip / path-traversal guard.

    The dSYM zip is a downloaded CI artifact (semi-trusted), but the
    extraction target is the cache dir, so we validate every member's
    resolved path stays under `dest` before extracting. Reject absolute
    paths and any member that escapes via `..`. Cheap hardening.
    """
    dest = dest.resolve()
    for member in zf.namelist():
        # Normalise the member's destination and ensure it stays under dest.
        target = (dest / member).resolve()
        try:
            target.relative_to(dest)
        except ValueError:
            raise RuntimeError(
                f"Refusing to extract '{member}': path escapes {dest} "
                f"(zip-slip / path-traversal attempt)."
            )
    zf.extractall(dest)


def _download_dsym(version):
    """gh run download the dSYM artifact for v<version>, extract the
    dSYM, and cache the DWARF binary under CACHE_DIR/<version>/.
    Returns the DWARF binary Path.

    Artifact-name resolution (P0-A landed two candidates):
      1. dsyms-<version>          (versioned 90-day artifact — preferred)
      2. ios-build-<run_number>   (7-day bundle; name uses run_NUMBER,
                                    NOT run_id/databaseId)
    We try both by NAME, then fall back to downloading every artifact of
    the run and letting the DWARF discovery sort it out.
    """
    run_id, run_number = _resolve_run(version)
    vdir = CACHE_DIR / version
    vdir.mkdir(parents=True, exist_ok=True)

    # Candidate artifact names, most-specific first. The ios-build name
    # is keyed on run_NUMBER (not databaseId) — only attempt it when we
    # actually resolved the number.
    candidates = [f"dsyms-{version}"]
    if run_number is not None:
        candidates.append(ARTIFACT_NAME_TMPL.format(run=run_number))

    print(f"  resolving dSYM for v{version} -> run {run_id} "
          f"(run_number {run_number}); trying artifacts {candidates}",
          file=sys.stderr)

    # Try each candidate artifact by NAME (smallest download), then fall
    # back to pulling every artifact of the run (this also drags in the
    # multi-MB IPA, so it is the last resort, not the default).
    got = False
    last_err = ""
    for artifact in candidates:
        rc, out, err = _run([
            "gh", "run", "download", str(run_id), "--repo", REPO,
            "--name", artifact, "--dir", str(vdir),
        ])
        if rc == 0:
            print(f"  downloaded artifact '{artifact}'", file=sys.stderr)
            got = True
            break
        last_err = err.strip() or out.strip()
        print(f"  artifact '{artifact}' miss ({last_err})", file=sys.stderr)

    if not got:
        # Last resort: download ALL artifacts of the run and let the DWARF
        # discovery sort it out (pulls the IPA too — slow but correct).
        print(f"  named artifacts all missed; downloading ALL artifacts "
              f"of run {run_id} (includes the IPA)", file=sys.stderr)
        rc, out, err = _run([
            "gh", "run", "download", str(run_id), "--repo", REPO,
            "--dir", str(vdir),
        ])
        if rc != 0:
            raise RuntimeError(
                f"gh run download failed for run {run_id}: "
                f"{err.strip() or out.strip() or last_err}"
            )

    # Unzip any *.zip we pulled (the dSYM is shipped zipped).
    for z in list(vdir.rglob("*.zip")):
        try:
            with zipfile.ZipFile(z) as zf:
                _safe_extract_all(zf, z.parent)
        except zipfile.BadZipFile:
            continue

    dwarf = _find_dwarf_binary(vdir)
    if dwarf is None:
        raise RuntimeError(
            f"dSYM downloaded but no DWARF/{IMAGE_NAME} binary found under "
            f"{vdir}. Contents: "
            f"{[p.name for p in vdir.iterdir()]}"
        )
    return dwarf


def get_dwarf(version, explicit_dsym):
    """Resolve a DWARF binary path from --dsym, cache, or gh download."""
    if explicit_dsym:
        p = Path(explicit_dsym)
        if p.is_file():
            return p  # already the DWARF binary
        if p.is_dir():
            dw = _find_dwarf_binary(p)
            if dw:
                return dw
        raise RuntimeError(f"--dsym path has no DWARF/{IMAGE_NAME}: {p}")

    if not version:
        raise RuntimeError(
            "No --version and no --dsym, and version not found in the crash "
            "dump. Pass --version 1.0.NNN or --dsym <path>."
        )

    cached = _cached_dwarf(version)
    if cached:
        print(f"  using cached dSYM: {cached}", file=sys.stderr)
        return cached
    return _download_dsym(version)


# --------------------------------------------------------------------------
# Symbolizer backends
# --------------------------------------------------------------------------

def _detect_text_vmaddr(dwarf: Path):
    """Best-effort read of the __TEXT segment vmaddr from the dSYM.

    Defaults to 0x100000000 (the universal arm64 PIE value). We only try
    to override it if the `symbolic` lib is available and reports a
    different image base — otherwise the default is correct.
    """
    try:
        from symbolic import Archive  # type: ignore
        archive = Archive.open(str(dwarf))
        for obj in archive.objects:
            # symbolic exposes the preferred image load address.
            base = getattr(obj, "load_address", None)
            if base:
                return int(base)
    except Exception:
        pass
    return DEFAULT_TEXT_VMADDR


def _symbolize_with_symbolic(dwarf: Path, addrs):
    """Use the `symbolic` python lib. Returns {addr: [ (func,file,line), ...]}."""
    from symbolic import Archive  # type: ignore
    archive = Archive.open(str(dwarf))
    obj = None
    for o in archive.objects:
        if o.kind == "debug" or o.has_debug_info:
            obj = o
            break
    if obj is None:
        obj = archive.objects[0]

    # Build the symcache once and look addresses up against it.
    from symbolic import SymCache  # type: ignore  # noqa: F401
    cache = obj.make_symcache()
    for a in addrs:
        results = []
        for sm in cache.lookup(a):
            results.append((
                sm.symbol or "<unknown>",
                sm.abs_path or sm.path or "<unknown>",
                sm.line or 0,
            ))
        out[a] = results or [("<unknown>", "<unknown>", 0)]
    return out


def _find_llvm_symbolizer():
    """Locate the NDK llvm-symbolizer.exe (newest NDK)."""
    if not NDK_ROOT.is_dir():
        return None
    versions = sorted(
        (p for p in NDK_ROOT.iterdir() if p.is_dir()),
        key=lambda p: p.name, reverse=True,
    )
    for v in versions:
        exe = (v / "toolchains" / "llvm" / "prebuilt" /
               "windows-x86_64" / "bin" / "llvm-symbolizer.exe")
        if exe.is_file():
            return exe
    return None


def _symbolize_with_llvm(dwarf: Path, addrs):
    """Use NDK llvm-symbolizer. Returns {addr: [ (func,file,line), ...]}."""
    exe = _find_llvm_symbolizer()
    if exe is None:
        raise RuntimeError(
            "llvm-symbolizer.exe not found under " + str(NDK_ROOT)
        )
    # llvm-symbolizer reads "0x<hexaddr>" lines on stdin (the object is
    # fixed via --obj=) and prints one block per address:
    # function\nfile:line[:col]\n ... \n\n   --inlines expands inlines.
    proc = subprocess.run(
        [str(exe), "--obj=" + str(dwarf), "--inlines",
         "--demangle", "--functions=linkage"],
        input="\n".join(f"0x{a:x}" for a in addrs) + "\n",
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )
    if proc.returncode != 0 and not proc.stdout:
        raise RuntimeError(
            f"llvm-symbolizer failed: {proc.stderr.strip()}"
        )

    # Output is grouped per input address; blocks separated by a blank line.
    blocks = proc.stdout.split("\n\n")
    out = {}
    for a, block in zip(addrs, blocks):
        results = []
        lines = [l for l in block.splitlines() if l.strip()]
        # Pairs: func line, then file:line:col line.
        for i in range(0, len(lines) - 1, 2):
            func = lines[i].strip()
            loc = lines[i + 1].strip()
            mloc = re.match(r"(?P<file>.*):(?P<line>\d+)(?::\d+)?$", loc)
            if mloc:
                results.append((func, mloc.group("file"),
                                int(mloc.group("line"))))
            else:
                results.append((func, loc, 0))
        out[a] = results or [("<unknown>", "<unknown>", 0)]
    return out


def symbolize(dwarf: Path, offsets, text_vmaddr):
    """Map image offsets -> symbol info. Returns {offset: [(func,file,line)]}."""
    addrs = [text_vmaddr + off for off in offsets]
    # Prefer `symbolic`; fall back to NDK llvm-symbolizer.
    backend = None
    try:
        import symbolic  # noqa: F401
        backend = "symbolic"
    except ImportError:
        backend = "llvm"

    print(f"  symbolizer backend: {backend} "
          f"(__TEXT vmaddr 0x{text_vmaddr:x})", file=sys.stderr)

    if backend == "symbolic":
        try:
            by_addr = _symbolize_with_symbolic(dwarf, addrs)
        except Exception as e:
            print(f"  symbolic backend error ({e}); "
                  f"falling back to llvm-symbolizer", file=sys.stderr)
            by_addr = _symbolize_with_llvm(dwarf, addrs)
    else:
        by_addr = _symbolize_with_llvm(dwarf, addrs)

    # Warn if EVERY frame came back unresolved — the usual cause is a
    # dSYM that doesn't match this build (wrong version), which otherwise
    # produces a confidently-wrong all-"<unknown>" backtrace silently.
    def _all_unknown(entries):
        return all(
            (not e) or all(func == "<unknown>" for (func, _f, _l) in e)
            for e in entries
        )
    if addrs and _all_unknown(by_addr.values()):
        print(
            "WARNING: every frame resolved to <unknown>. The dSYM almost "
            "certainly does NOT match this build — verify the --version / "
            "--dsym corresponds to the crashing build's CFBundleVersion.",
            file=sys.stderr,
        )

    # Re-key by offset for the caller.
    return {off: by_addr[text_vmaddr + off] for off in offsets}


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Symbolicate a stripped iOS (QAudionApp) crash stack "
                    "to file:line without a Mac.")
    ap.add_argument("--crash", type=str,
                    help="path to crash dump / W417 log (else read stdin)")
    ap.add_argument("--version", type=str,
                    help="build version e.g. 1.0.662 (else auto-detected "
                         "from the dump)")
    ap.add_argument("--dsym", type=str,
                    help="path to an extracted .dSYM (or its DWARF binary); "
                         "skips gh download")
    ap.add_argument("--vmaddr", type=str, default=None,
                    help="override __TEXT vmaddr (hex, default 0x100000000)")
    args = ap.parse_args()

    # 1) Load crash text.
    if args.crash:
        text = Path(args.crash).read_text(encoding="utf-8", errors="replace")
    else:
        if sys.stdin.isatty():
            print("ERROR: no --crash file and nothing on stdin.",
                  file=sys.stderr)
            sys.exit(2)
        text = sys.stdin.read()

    # 2) Parse frames + fatal + version.
    frames, fatal, version_guess = parse_crash(text)
    version = args.version or version_guess

    # If we couldn't auto-detect the app's 1.0.NNN version but the dump
    # DOES contain some other X.Y.Z token (almost certainly a dependency
    # version like onnxruntime 1.24.2), warn loudly rather than silently
    # resolving the wrong dSYM. The operator must pass --version.
    if not args.version and version_guess is None:
        other = _ANY_VERSION_RE.search(text)
        if other:
            print(
                f"WARNING: no app 1.0.NNN version found in the dump, but a "
                f"version-looking token '{other.group('ver')}' is present "
                f"(likely a dependency, NOT the app). Refusing to guess — "
                f"pass --version 1.0.NNN explicitly.",
                file=sys.stderr,
            )

    if not frames:
        print("No QAudionApp frames found in input.", file=sys.stderr)
        if fatal:
            print(f"\nAssert site (from 'fatal:' line):")
            print(f"  {fatal['file']}:{fatal['line']}  {fatal['msg']}")
            sys.exit(0)
        sys.exit(1)

    print(f"=== symbolicate: {len(frames)} {IMAGE_NAME} frame(s), "
          f"version={version or '?'} ===", file=sys.stderr)

    # 3) Resolve the dSYM (cache / gh download / explicit).
    try:
        dwarf = get_dwarf(version, args.dsym)
    except Exception as e:
        print(f"ERROR resolving dSYM: {e}", file=sys.stderr)
        # Still print the fatal assert line — it's already file:line.
        if fatal:
            print(f"\nAssert site (from 'fatal:' line, no dSYM needed):")
            print(f"  {fatal['file']}:{fatal['line']}  {fatal['msg']}")
        sys.exit(1)

    # 4) __TEXT vmaddr (default 0x100000000, override via --vmaddr).
    if args.vmaddr:
        text_vmaddr = int(args.vmaddr, 16)
    else:
        text_vmaddr = _detect_text_vmaddr(dwarf)

    # 5) Symbolize.
    offsets = [f["offset"] for f in frames]
    try:
        results = symbolize(dwarf, offsets, text_vmaddr)
    except Exception as e:
        print(f"ERROR symbolizing: {e}", file=sys.stderr)
        sys.exit(1)

    # 6) Print the symbolicated backtrace.
    print(f"\n=== Symbolicated backtrace ({IMAGE_NAME} v{version or '?'}) ===")
    for f in frames:
        off = f["offset"]
        static_addr = text_vmaddr + off
        entries = results.get(off) or [("<unknown>", "<unknown>", 0)]
        # Top (innermost) frame first; inlined frames indented.
        for j, (func, file, line) in enumerate(entries):
            short_file = file
            # Trim absolute CI paths to something readable.
            m = re.search(r"(QAudion[^\\/].*)$", file.replace("\\", "/"))
            if m:
                short_file = m.group(1)
            prefix = (f"#{f['idx']:<2} 0x{static_addr:012x} (+{off})"
                      if j == 0 else "        -> inlined")
            loc = f"{short_file}:{line}" if line else short_file
            print(f"{prefix}  {func}")
            print(f"                                   at {loc}")

    # 7) Echo the Swift assert site (already file:line, dSYM-independent).
    if fatal:
        print(f"\n=== Swift trap site (from 'fatal:' line) ===")
        print(f"  {fatal['file']}:{fatal['line']}")
        print(f"  {fatal['msg']}")

    print(f"\ndSYM: {dwarf}")


if __name__ == "__main__":
    main()
