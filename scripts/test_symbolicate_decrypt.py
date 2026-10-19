#!/usr/bin/env python3
"""Tests for the age-encrypted dSYM path of scripts/symbolicate.py (stdlib only, offline).

Run:  python3 -I scripts/test_symbolicate_decrypt.py

The dSYM artifacts are age-encrypted because the repository is public (ios-testflight.yml
step 11); symbolicate.py decrypts them on the key host, where the private key is. These tests use
throwaway keys and a fake `ssh` that runs the "remote" command locally, so they need `age` and
`age-keygen` (scripts/ci/install-age.sh puts the pinned release on PATH) and a POSIX shell; without them the cases that need them are skipped, and the pure
logic cases still run.
"""
import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("symbolicate", HERE / "symbolicate.py")
sym = importlib.util.module_from_spec(SPEC)
sys.modules["symbolicate"] = sym
SPEC.loader.exec_module(sym)


def _find(name):
    found = shutil.which(name)
    if found:
        return found
    cand = Path("~/go/bin/" + name).expanduser()
    return str(cand) if cand.is_file() else None


AGE = _find("age")
AGE_KEYGEN = _find("age-keygen")
POSIX = os.name == "posix"
HAVE_AGE = bool(AGE and AGE_KEYGEN)


def make_key(tmp):
    key = Path(tmp) / "test.key"
    subprocess.run([AGE_KEYGEN, "-o", str(key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rcpt = subprocess.run([AGE_KEYGEN, "-y", str(key)], check=True, stdout=subprocess.PIPE).stdout.decode().strip()
    return key, rcpt


def encrypt(rcpt, src, dst):
    subprocess.run([AGE, "-r", rcpt, "-o", str(dst), str(src)], check=True)


def write_fake_ssh(directory):
    """A fake `ssh -o BatchMode=yes HOST CMD...`: runs CMD locally through sh, like the remote shell would."""
    path = Path(directory) / "ssh"
    path.write_text('#!/bin/sh\n'
                    '# fake ssh for tests: drop "-o BatchMode=yes HOST", run the command with sh -c\n'
                    'echo "$@" >> "${FAKE_SSH_LOG:-/dev/null}"\n'
                    'shift 3\n'
                    'exec sh -c "$1"\n')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class PureLogicTests(unittest.TestCase):
    def test_artifact_is_named_by_version_and_there_is_no_ios_build_artifact(self):
        self.assertEqual(sym.ARTIFACT_NAME_TMPL.format(version="1.0.662"), "dsyms-1.0.662")
        source = (HERE / "symbolicate.py").read_text(encoding="utf-8")
        code = "\n".join(l for l in source.splitlines() if not l.strip().startswith("#"))
        # `ios-build` may only be mentioned in prose that says it is gone; no artifact of that name is requested
        self.assertNotIn('"ios-build', code)
        self.assertNotIn("ios-build-{", code)

    def test_ssh_client_selection(self):
        with mock.patch.dict(os.environ, {"QAUDION_SSH": "/opt/custom/ssh"}):
            self.assertEqual(sym._ssh_bin(), "/opt/custom/ssh")
        env = {k: v for k, v in os.environ.items() if k != "QAUDION_SSH"}
        with tempfile.TemporaryDirectory() as tmp:
            winssh = Path(tmp) / "System32" / "OpenSSH" / "ssh.exe"
            winssh.parent.mkdir(parents=True)
            winssh.write_text("")
            with mock.patch.dict(os.environ, dict(env, SystemRoot=tmp), clear=True), \
                    mock.patch.object(sym, "IS_WINDOWS", True):
                self.assertEqual(sym._ssh_bin(), str(winssh),
                                 "on Windows the system OpenSSH (the agent's) must win over Git's ssh")
            with mock.patch.dict(os.environ, dict(env, SystemRoot=tmp + "-none"), clear=True), \
                    mock.patch.object(sym, "IS_WINDOWS", True), \
                    mock.patch.object(sym.shutil, "which", return_value="/usr/bin/ssh"):
                self.assertEqual(sym._ssh_bin(), "/usr/bin/ssh")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(sym, "IS_WINDOWS", False), \
                mock.patch.object(sym.shutil, "which", return_value="/usr/bin/ssh"):
            self.assertEqual(sym._ssh_bin(), "/usr/bin/ssh")

    def test_remote_path_characters_are_restricted(self):
        self.assertTrue(sym._SAFE_REMOTE_PATH.match("~/go/bin/age"))
        self.assertTrue(sym._SAFE_REMOTE_PATH.match("~/.config/some-app/key-file.txt"))
        for bad in ["age; rm -rf /", "age $(id)", "a b", "a`id`", "a|b", "a&b", "a'b", 'a"b', "a\nb", ""]:
            self.assertFalse(sym._SAFE_REMOTE_PATH.match(bad), repr(bad))

    def test_no_key_and_no_ssh_is_a_clear_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "a.zip.age"
            src.write_bytes(b"x")
            dst = Path(tmp) / "a.zip"
            with mock.patch.object(sym, "AGE_KEY_PATH", Path(tmp) / "missing.key"), \
                    mock.patch.object(sym, "_ssh_bin", return_value=None), \
                    mock.patch.object(sym, "_local_age", return_value=None):
                with self.assertRaises(RuntimeError) as cm:
                    sym._decrypt_age(src, dst)
            self.assertIn("cannot decrypt", str(cm.exception))
            self.assertFalse(dst.exists())


@unittest.skipUnless(HAVE_AGE and POSIX, "needs age, age-keygen and a POSIX shell")
class DecryptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.key, self.rcpt = make_key(self.dir)
        self.plain = self.dir / "QAudionApp.app.dSYM.zip"
        self.plain.write_bytes(os.urandom(4096))
        self.enc = self.dir / "QAudionApp.app.dSYM.zip.age"
        encrypt(self.rcpt, self.plain, self.enc)

    def test_the_encrypted_file_is_not_the_plaintext(self):
        self.assertTrue(self.enc.read_bytes().startswith(b"age-encryption.org/v1"))
        self.assertNotIn(self.plain.read_bytes()[:64], self.enc.read_bytes())

    def test_local_route_when_the_key_is_on_this_host(self):
        out = self.dir / "local.zip"
        with mock.patch.object(sym, "AGE_KEY_PATH", self.key), mock.patch.object(sym, "_local_age", return_value=AGE):
            sym._decrypt_age(self.enc, out)
        self.assertEqual(out.read_bytes(), self.plain.read_bytes())

    def test_ssh_route_pipes_the_ciphertext_and_never_copies_the_key(self):
        bindir = self.dir / "bin"
        bindir.mkdir()
        write_fake_ssh(bindir)
        log = self.dir / "ssh.log"
        out = self.dir / "remote.zip"
        env = {"PATH": str(bindir) + os.pathsep + os.environ.get("PATH", ""), "FAKE_SSH_LOG": str(log)}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(sym, "AGE_KEY_PATH", self.dir / "no-such.key"), \
                mock.patch.object(sym, "_local_age", return_value=None), \
                mock.patch.object(sym, "REMOTE_AGE", AGE), \
                mock.patch.object(sym, "REMOTE_KEY", str(self.key)), \
                mock.patch.object(sym, "DECRYPT_HOST", "keyhost"):
            sym._decrypt_age(self.enc, out)
        self.assertEqual(out.read_bytes(), self.plain.read_bytes())
        logged = log.read_text()
        self.assertIn("BatchMode=yes", logged)
        self.assertIn("keyhost", logged)
        self.assertIn(" -d -i ", logged)
        # the key file content never travelled: only its PATH is on the command line
        self.assertNotIn("AGE-SECRET-KEY", logged)
        self.assertNotIn(self.key.read_text().splitlines()[-1], logged)

    def test_wrong_key_fails_and_leaves_no_output(self):
        sub = self.dir / "other"
        sub.mkdir()
        other_key, _ = make_key(sub)
        out = self.dir / "wrong.zip"
        with mock.patch.object(sym, "AGE_KEY_PATH", other_key), mock.patch.object(sym, "_local_age", return_value=AGE):
            with self.assertRaises(RuntimeError) as cm:
                sym._decrypt_age(self.enc, out)
        self.assertIn("age failed", str(cm.exception))
        self.assertFalse(out.exists())
        self.assertNotIn("AGE-SECRET-KEY", str(cm.exception))

    def test_ssh_route_failure_leaves_no_output(self):
        bindir = self.dir / "bin2"
        bindir.mkdir()
        write_fake_ssh(bindir)
        out = self.dir / "fail.zip"
        with mock.patch.dict(os.environ, {"PATH": str(bindir) + os.pathsep + os.environ.get("PATH", "")}), \
                mock.patch.object(sym, "AGE_KEY_PATH", self.dir / "no-such.key"), \
                mock.patch.object(sym, "_local_age", return_value=None), \
                mock.patch.object(sym, "REMOTE_AGE", AGE), \
                mock.patch.object(sym, "REMOTE_KEY", str(self.dir / "does-not-exist.key")):
            with self.assertRaises(RuntimeError):
                sym._decrypt_age(self.enc, out)
        self.assertFalse(out.exists())

    def test_unsafe_remote_path_is_refused_before_anything_runs(self):
        bindir = self.dir / "bin3"
        bindir.mkdir()
        write_fake_ssh(bindir)
        log = self.dir / "ssh3.log"
        with mock.patch.dict(os.environ, {"PATH": str(bindir) + os.pathsep + os.environ.get("PATH", ""),
                                          "FAKE_SSH_LOG": str(log)}), \
                mock.patch.object(sym, "AGE_KEY_PATH", self.dir / "no-such.key"), \
                mock.patch.object(sym, "_local_age", return_value=None), \
                mock.patch.object(sym, "REMOTE_AGE", "age; touch /tmp/pwned"):
            with self.assertRaises(RuntimeError):
                sym._decrypt_age(self.enc, self.dir / "x.zip")
        self.assertFalse(log.exists(), "ssh must not have been run")

    def test_decrypt_all_replaces_the_age_files(self):
        vdir = self.dir / "vdir"
        (vdir / "sub").mkdir(parents=True)
        shutil.copy(self.enc, vdir / "A.zip.age")
        shutil.copy(self.enc, vdir / "sub" / "B.zip.age")
        (vdir / "C.zip").write_bytes(b"already plain")
        with mock.patch.object(sym, "AGE_KEY_PATH", self.key), mock.patch.object(sym, "_local_age", return_value=AGE):
            sym._decrypt_all(vdir)
        self.assertEqual((vdir / "A.zip").read_bytes(), self.plain.read_bytes())
        self.assertEqual((vdir / "sub" / "B.zip").read_bytes(), self.plain.read_bytes())
        self.assertEqual((vdir / "C.zip").read_bytes(), b"already plain")
        self.assertEqual(list(vdir.rglob("*.age")), [])

    def test_download_pipeline_decrypts_then_extracts_and_finds_the_dwarf(self):
        """gh is stubbed: it 'downloads' an artifact holding an encrypted dSYM zip."""
        cache = self.dir / "cache"
        # build a dSYM zip with the layout the finder expects
        zsrc = self.dir / "dsym.zip"
        with zipfile.ZipFile(zsrc, "w") as zf:
            zf.writestr("QAudionApp.app.dSYM/Contents/Resources/DWARF/QAudionApp", b"\xcf\xfa\xed\xfe" + b"\0" * 64)
        enc = self.dir / "QAudionApp.app.dSYM.zip.age"
        encrypt(self.rcpt, zsrc, enc)

        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            if cmd[:3] == ["gh", "run", "download"]:
                target = Path(cmd[cmd.index("--dir") + 1])
                shutil.copy(enc, target / "QAudionApp.app.dSYM.zip.age")
                return 0, "", ""
            return 1, "", "unexpected"

        with mock.patch.object(sym, "CACHE_DIR", cache), \
                mock.patch.object(sym, "_resolve_run", return_value=(111, 22)), \
                mock.patch.object(sym, "_run", side_effect=fake_run), \
                mock.patch.object(sym, "AGE_KEY_PATH", self.key), \
                mock.patch.object(sym, "_local_age", return_value=AGE):
            dwarf = sym._download_dsym("1.0.999")
        self.assertTrue(dwarf.is_file())
        self.assertEqual(dwarf.name, "QAudionApp")
        # the artifact asked for is the versioned one, nothing called ios-build-*
        names = [c[c.index("--name") + 1] for c in calls if "--name" in c]
        self.assertEqual(names, ["dsyms-1.0.999"])
        self.assertEqual(list((cache / "1.0.999").rglob("*.age")), [])

    def test_a_plain_zip_from_before_the_encryption_is_still_extracted(self):
        cache = self.dir / "cache2"
        zsrc = self.dir / "plain.zip"
        with zipfile.ZipFile(zsrc, "w") as zf:
            zf.writestr("QAudionApp.app.dSYM/Contents/Resources/DWARF/QAudionApp", b"\xcf\xfa\xed\xfe" + b"\0" * 64)

        def fake_run(cmd, **kw):
            target = Path(cmd[cmd.index("--dir") + 1])
            shutil.copy(zsrc, target / "QAudionApp.dSYMs.raw.zip")
            return 0, "", ""

        with mock.patch.object(sym, "CACHE_DIR", cache), \
                mock.patch.object(sym, "_resolve_run", return_value=(1, 2)), \
                mock.patch.object(sym, "_run", side_effect=fake_run):
            dwarf = sym._download_dsym("1.0.1")
        self.assertTrue(dwarf.is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
