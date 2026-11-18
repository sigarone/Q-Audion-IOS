import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_public_text.py")
_spec = importlib.util.spec_from_file_location("check_public_text", SCRIPT)
c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(c)


def sha(word):
    return hashlib.sha256(word.encode("utf-8")).hexdigest()


def listed_names():
    """The names of NAME_HASHES, assembled from pieces: no file of this repository spells one out."""
    return [
        "-".join(("qaudion", "android", "new")),
        "-".join(("new", "q", "audion", "android")),
        "-".join(("q", "audion", "android")),
        "-".join(("bcrypto", "server")),
        "-".join(("qaudion", "voice", "lab")),
        "-".join(("qaudion", "firmware")),
        "-".join(("qaudion", "earbuds")),
        "-".join(("qaudion", "desktop")),
        "-".join(("q", "audion", "desktop")),
        "-".join(("bcrypto", "control", "room")),
        "-".join(("qaudion", "crypto", "core")),
        "-".join(("claude", "lab", "kit")),
        "hel" + "sinki",
        "aru" + "ba",
        "io" + "nos",
        "-".join(("fi", "1")),
    ]


OKAY_NAME = "-".join(("qaudion", "crypto", "core", "spm"))
PRODUCT_WORD = "-".join(("bcrypto", "server"))


def rules(text, scope=c.COMMENT):
    return sorted(r for r, _ in c.problems_in(text, scope))


class RuleTable(unittest.TestCase):
    def check(self, hits, misses, rule, scope=c.COMMENT):
        for t in hits:
            self.assertEqual(rules(t, scope), [rule], t)
        for t in misses:
            self.assertEqual(rules(t, scope), [], t)

    def test_internal_note(self):
        self.check(
            ("see the audit memory", "as the Memory File says", "in reference_foo.md", "see project_notes",
             "feedback_x", "the crypto_protocol_audit file"),
            ("memory is freed here", "a regression test", "an audit of the inputs", "the field is optional",
             "a reference frame", "my_project_x is a name", "projects are listed", "a memory-mapped file"),
            "internal-note")

    def test_finding_code(self):
        self.check(
            ("ADR-12", "see TRUST-3 for it", "SECURITY C-7", "security: c-12", "Task-42"),
            ("C-7 on its own", "adr-x", "a task-based design", "Task 12", "a trust-based design", "ADR 12"),
            "finding-code")

    def test_call_id(self):
        self.check(
            ("call 1a2b3c4d", "on call 1A2B3C4D it ended", "call_id=1a2b3c4d", 'callId: "1a2b3c4d"',
             "the call that ended 1a2b3c4d", "call `1a2b3c4d`"),
            ("call 1a2b3c4d5e", "a call hash is not here 1a2b3c4d", "sha 1a2b3c4d", "recall 1a2b3c4d",
             "calls 1a2b3c4d", "the callee 1a2b3c4d", "call abcdefg1", "call 1234567", "an id of 1a2b3c4d"),
            "call-id")

    def test_incident(self):
        self.check(
            ("an incident", "Incidents were seen", "a live incident"),
            ("incidental", "the field is private", "a real call setup", "a live view", "in the fields of a record",
             "the text field is empty", "the NFC field is off", "seen in the field", "it ran on a real call",
             "it ran on a live call"),
            "incident")

    def test_co_author_is_for_commit_text_only(self):
        trailer = "Co-Authored-By: A Name <a@example.invalid>"
        self.assertEqual(rules(trailer, c.COMMIT), ["co-author"])
        self.assertEqual(rules("co-authored-by: x", c.COMMIT), ["co-author"])
        self.assertEqual(rules(trailer, c.COMMENT), [])
        self.assertEqual(rules("it mentions Co-Authored-By: in the middle", c.COMMIT), [])

    def test_commit_text_also_gets_the_comment_rules(self):
        self.assertEqual(rules("an incident", c.COMMIT), ["incident"])

    def test_names(self):
        for n in listed_names():
            variants = ["see " + n + " for it", "path/to/" + n + "/file.swift", "https://example.invalid/org/" + n + ".git",
                        n.upper(), n + "-extra", "(" + n + ")", "x: " + n]
            if "-" in n:
                variants.append(n.replace("-", "_"))
            for text in variants:
                self.assertEqual(rules(text), ["internal-name"], text)
                self.assertEqual(rules(text, c.COMMIT), ["internal-name"], text)

    def test_names_that_are_fine(self):
        for text in (OKAY_NAME, "org/" + OKAY_NAME + ".git", OKAY_NAME + "-tests", "github.com/x/" + OKAY_NAME,
                     "hel sinki", "bcrypto server", "fi-" + "10", "wi-fi", "a-fi", "io" + "no", "hel" + "sinkis"):
            self.assertEqual(rules(text), [], text)

    def test_product_word_is_fine_in_text_the_app_shows(self):
        text = "Zum " + PRODUCT_WORD.title() + " aufgelöst"
        self.assertEqual(rules(text, c.COMMENT), ["internal-name"])
        self.assertEqual(rules(text, c.SHIPPED), [])
        host = "hel" + "sinki"
        self.assertEqual(rules("on " + host, c.SHIPPED), ["internal-name"])

    def test_things_that_are_not_blocked(self):
        for text in ("W-MEDIADEAD marks the line", "sha256 deadbeefcafebabe0011", "vector 00112233445566778899aabbccddeeff",
                     "the memory budget", "a regression test of the audit", "the field order"):
            self.assertEqual(rules(text), [], text)


class Extraction(unittest.TestCase):
    SWIFT = "\n".join([
        'let a = 1 // one',                                    # 1
        '/// two',                                             # 2
        'let url = "https://example.invalid/x" // three',      # 3
        '/* four',                                             # 4
        '   five */ let b = 2',                                # 5
        'let s = "text // not a comment"',                     # 6
        'let m = """',                                         # 7
        '// not a comment either',                             # 8
        '"""',                                                 # 9
        'let r = #"raw // still text"#',                       # 10
        'let i = "a \\(f("x // y")) b" // six',                # 11
        '/* outer /* nested */ still comment */ let c = 3 // seven',  # 12
        'let e = "" // eight',                                 # 13
        'let t = "q\\"uote // inside"',                        # 14
        'let u = 1',                                           # 15
    ])

    def test_swift(self):
        out = c.swift_comments(self.SWIFT)
        for line, word in ((1, "one"), (2, "two"), (3, "three"), (4, "four"), (5, "five"), (11, "six"),
                           (12, "still comment"), (12, "seven"), (13, "eight")):
            self.assertIn(word, out.get(line, ""), (line, word))
        for line in (6, 7, 8, 9, 10, 14, 15):
            self.assertNotIn(line, out, line)
        self.assertNotIn("x // y", out[11])

    def test_swift_unterminated_string_does_not_hide_the_rest(self):
        out = c.swift_comments('let a = "open\nlet b = 1 // after\n')
        self.assertIn("after", out.get(2, ""))

    def test_swift_raw_string_of_quotes_is_not_a_multi_line_string(self):
        out = c.swift_comments('let a = #""""#\n// c\nlet b = 1 // two\n')
        self.assertEqual(sorted(out), [2, 3])
        out = c.swift_comments('let a = #"""#\nlet z = ""\n// d\n')
        self.assertEqual(sorted(out), [3])
        out = c.swift_comments('let m = """   \n// text\n"""\n// e\n')  # blanks after the opening still make it multi-line
        self.assertEqual(sorted(out), [4])

    def test_python(self):
        src = "\n".join(['x = 1  # one', 's = "a # not"', "d = '''doc # not", "more # not'''", "# two", ""])
        out = c.py_comments(src)
        self.assertEqual(sorted(out), [1, 5])
        self.assertIn("one", out[1])
        self.assertIn("two", out[5])

    def test_python_that_does_not_tokenize_falls_back_to_the_line_scan(self):
        out = c.py_comments("x = (  # one\n")
        self.assertIn("one", out.get(1, ""))

    def test_hash_comment(self):
        self.assertEqual(c.hash_comment("key: value # one"), " one")
        self.assertEqual(c.hash_comment('echo "a # b" # c'), " c")
        self.assertEqual(c.hash_comment("# first"), " first")
        for line in ("a#b", "url: http://x/#frag", "n=${#arr[@]}", "echo '# not'", "plain"):
            self.assertEqual(c.hash_comment(line), "", line)
        self.assertEqual(c.hash_comment("name: Don't # c"), " c")

    def test_other_formats(self):
        self.assertEqual(c.text_of_added_line(".md", "an incident"), ("an incident", c.COMMENT))
        self.assertEqual(c.text_of_added_line(".xcstrings", '            "comment" : "a note",'), ("a note", c.COMMENT))
        self.assertEqual(c.text_of_added_line(".xcstrings", '            "value" : "shown"'), ("shown", c.SHIPPED))
        self.assertEqual(c.text_of_added_line(".xcstrings", '            "state" : "translated",'), ("", c.COMMENT))
        text, scope = c.text_of_added_line(".plist", "<string>shown</string> <!-- a note -->")
        self.assertEqual(scope, c.SHIPPED)
        self.assertIn("shown", text)
        self.assertIn("a note", text)
        self.assertNotIn("<", text)


class TempRepo:
    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.dir = self._tmp.name
        self.git("init", "-q")

    def git(self, *args):
        cmd = ["git", "-C", self.dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
               "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", *args]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
        if p.returncode != 0:
            raise RuntimeError(p.stderr)
        return p.stdout.strip()

    def write(self, path, text):
        full = os.path.join(self.dir, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def close(self):
        self._tmp.cleanup()


class DiffScan(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def scan(self, base, head, pr=None):
        return c.check_range(self.repo.dir, base, head, pr)

    def places(self, hits):
        return sorted((h.place(), h.rule) for h in hits)

    def test_only_added_comments_count(self):
        self.repo.write("A.swift", "// old: see the audit memory\nlet a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "// old: see the audit memory\nlet a = 1\n// new: see the audit memory\nlet b = 2 // fine\n")
        head = self.repo.commit("Add")
        hits, skipped, nlines, nfiles, texts = self.scan(base, head)
        self.assertEqual(self.places(hits), [("A.swift:3", "internal-note")])
        self.assertEqual((skipped, nlines, nfiles, texts), (0, 2, 1, 1))

    def test_removed_lines_never_count(self):
        self.repo.write("A.swift", "// an incident\nlet a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "// a clean line\nlet a = 1\n")
        head = self.repo.commit("Edit")
        self.assertEqual(self.scan(base, head)[0], [])

    def test_removed_lines_never_count_in_the_other_formats(self):
        self.repo.write("README.md", "an incident\nkept\n")
        self.repo.write("ci.yml", "# an incident\nkey: value\n")
        self.repo.write("tool.py", "# an incident\nx = 1\n")
        self.repo.write("run.sh", "# an incident\ntrue\n")
        base = self.repo.commit("Base")
        self.repo.write("README.md", "kept\n")
        self.repo.write("ci.yml", "key: value\n")
        self.repo.write("tool.py", "# clean\nx = 1\n")
        self.repo.write("run.sh", "true\n")
        head = self.repo.commit("Edit")
        hits, _, nlines, nfiles, _ = self.scan(base, head)
        self.assertEqual(hits, [])
        self.assertEqual((nlines, nfiles), (1, 1))

    def test_a_branch_behind_its_base_reports_only_its_own_lines(self):
        self.repo.write("A.swift", "// an incident\nlet a = 1\n")
        self.repo.write("B.swift", "let b = 1\n")
        fork = self.repo.commit("Fork")
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("B.swift", "let b = 1\n// own: an incident\n")
        feature = self.repo.commit("Feature")
        self.repo.git("checkout", "-q", fork)
        self.repo.write("A.swift", "// a clean line\nlet a = 1\n// newer: see TRUST-3\n")
        main = self.repo.commit("Newer on the base\n\nsee ADR-12")
        hits, _, nlines, nfiles, texts = self.scan(main, feature)
        self.assertEqual(self.places(hits), [("B.swift:2", "incident")])
        self.assertEqual((nlines, nfiles, texts), (1, 1, 1))

    def test_wire_spec_at_the_root_is_not_read_and_nothing_else_is_left_out(self):
        self.repo.write("WIRE_SPEC.md", "a line\n")
        self.repo.write("docs/WIRE_SPEC.md", "a line\n")
        base = self.repo.commit("Base")
        self.repo.write("WIRE_SPEC.md", "a line\nan incident\n")
        self.repo.write("docs/WIRE_SPEC.md", "a line\nan incident\n")
        self.repo.write("OTHER_SPEC.md", "an incident\n")
        head = self.repo.commit("Add")
        hits, _, nlines, nfiles, _ = self.scan(base, head)
        self.assertEqual(self.places(hits), [("OTHER_SPEC.md:1", "incident"), ("docs/WIRE_SPEC.md:2", "incident")])
        self.assertEqual((nlines, nfiles), (2, 2))

    def test_a_local_diff_prefix_setting_does_not_hide_the_hits(self):
        self.repo.write("A.swift", "let a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "let a = 1\n// an incident\n")
        head = self.repo.commit("Add")
        self.repo.git("config", "diff.noprefix", "true")
        self.assertEqual(self.places(self.scan(base, head)[0]), [("A.swift:2", "incident")])
        self.repo.git("config", "--unset", "diff.noprefix")
        self.repo.git("config", "diff.srcPrefix", "x/")
        self.repo.git("config", "diff.dstPrefix", "y/")
        self.assertEqual(self.places(self.scan(base, head)[0]), [("A.swift:2", "incident")])

    def test_a_local_inter_hunk_setting_does_not_move_the_lines(self):
        self.repo.write("A.swift", "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "// an incident\nlet a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n// an incident\n")
        head = self.repo.commit("Add")
        self.repo.git("config", "diff.interHunkContext", "10")
        self.assertEqual(self.places(self.scan(base, head)[0]), [("A.swift:1", "incident"), ("A.swift:6", "incident")])

    def test_code_and_strings_are_not_read(self):
        self.repo.write("A.swift", "")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", 'let incident = 1\nlet s = "an incident // in a string"\nlet t = "x" // clean\n')
        head = self.repo.commit("Add")
        self.assertEqual(self.scan(base, head)[0], [])

    def test_line_inside_a_block_comment_that_started_earlier(self):
        self.repo.write("A.swift", "/* start\n   end */\nlet a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "/* start\n   middle: an incident\n   end */\nlet a = 1\n")
        head = self.repo.commit("Add")
        self.assertEqual(self.places(self.scan(base, head)[0]), [("A.swift:2", "incident")])

    def test_marker_skips_the_line_and_is_counted(self):
        self.repo.write("A.swift", "")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "// an incident " + c.MARKER + "\n// another incident\n")
        head = self.repo.commit("Add")
        hits, skipped, *_ = self.scan(base, head)
        self.assertEqual(self.places(hits), [("A.swift:2", "incident")])
        self.assertEqual(skipped, 1)

    def test_renamed_file_with_the_same_text_is_not_added_text(self):
        self.repo.write("Old.swift", "// an incident\n" + "let a = 1\n" * 5)
        base = self.repo.commit("Base")
        self.repo.git("mv", "Old.swift", "New.swift")
        head = self.repo.commit("Move")
        self.assertEqual(self.scan(base, head)[0], [])

    def test_other_formats(self):
        self.repo.write("README.md", "")
        base = self.repo.commit("Base")
        self.repo.write("README.md", "clean\nan incident happened\n")
        self.repo.write("ci.yml", 'run: echo "incident"\n# an incident\nfoo: bar # task-12\n')
        self.repo.write("tool.py", 'S = "an incident"\n# audit memory\n')
        self.repo.write("run.sh", "echo ok # call 1a2b3c4d\n")
        self.repo.write("Info.plist", "<string>a note</string>\n<!-- an incident -->\n")
        self.repo.write("Loc.xcstrings", '    "comment" : "an incident",\n    "value" : "fine"\n')
        self.repo.write("data.txt", "an incident\n")
        head = self.repo.commit("Add")
        hits = self.scan(base, head)[0]
        self.assertEqual(self.places(hits), [
            ("Info.plist:2", "incident"), ("Loc.xcstrings:1", "incident"), ("README.md:2", "incident"),
            ("ci.yml:2", "incident"), ("ci.yml:3", "finding-code"), ("run.sh:1", "call-id"),
            ("tool.py:2", "internal-note")])

    def test_commit_messages_title_and_body(self):
        self.repo.write("A.swift", "let a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "let a = 2\n")
        self.repo.commit("Change a\n\nCo-Authored-By: A Name <a@example.invalid>\nan incident\n")
        self.repo.write("A.swift", "let a = 3\n")
        head = self.repo.commit("Change a again")
        hits, _, _, _, texts = self.scan(base, head, ("A clean title", "a body\nsee TRUST-3"))
        self.assertEqual(texts, 4)
        got = sorted((h.where.split(" ")[0] + " " + h.where.split(" ")[1] if h.where.startswith("PR") else "commit", h.line, h.rule)
                     for h in hits)
        self.assertEqual(got, [("PR body", 2, "finding-code"), ("commit", 3, "co-author"), ("commit", 4, "incident")])
        self.assertTrue(all(h.where.startswith(("PR ", "commit ")) for h in hits))

    def test_marker_on_a_commit_line(self):
        self.repo.write("A.swift", "let a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "let a = 2\n")
        head = self.repo.commit("Change\n\nan incident " + c.MARKER)
        hits, skipped, *_ = self.scan(base, head)
        self.assertEqual((hits, skipped), ([], 1))

    def run_cli(self, *extra, env=None):
        e = dict(os.environ, **(env or {}))
        return subprocess.run([sys.executable, "-I", SCRIPT, "--repo", self.repo.dir, *extra],
                              capture_output=True, text=True, encoding="utf-8", env=e)

    def test_cli_exit_codes_and_output(self):
        self.repo.write("A.swift", "let a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "let a = 1\n// clean\n")
        good = self.repo.commit("Clean")
        self.repo.write("A.swift", "let a = 1\n// clean\n// an incident\n")
        bad = self.repo.commit("Bad")
        ok = self.run_cli("--base", base, "--head", good)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("0 hits", ok.stdout)
        no = self.run_cli("--base", base, "--head", bad, env={"GITHUB_ACTIONS": "true"})
        self.assertEqual(no.returncode, 1)
        self.assertIn("A.swift:3: incident:", no.stderr)
        self.assertNotIn("an incident", no.stderr + no.stdout)
        self.assertIn("::error file=A.swift,line=3,title=Public text check::incident:", no.stdout)
        shown = self.run_cli("--base", base, "--head", bad, "--show-text")
        self.assertIn("an incident", shown.stderr)
        self.assertEqual(self.run_cli("--base", "no-such-commit", "--head", bad).returncode, 2)
        self.assertEqual(self.run_cli("--base", "--oops", "--head", bad).returncode, 2)

    def test_cli_reads_title_and_body_from_an_event_payload_or_an_api_object(self):
        self.repo.write("A.swift", "let a = 1\n")
        base = self.repo.commit("Base")
        self.repo.write("A.swift", "let a = 2\n")
        head = self.repo.commit("Change")
        path = os.path.join(self.repo.dir, "..", "pr-%d.json" % os.getpid())
        try:
            for payload in ({"pull_request": {"title": "An incident", "body": None}}, {"title": "A title", "body": "see ADR-12"}):
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(payload, f)
                r = self.run_cli("--base", base, "--head", head, "--pr-json", path)
                self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"title": "A title", "body": "A body"}, f)
            self.assertEqual(self.run_cli("--base", base, "--head", head, "--pr-json", path).returncode, 0)
        finally:
            if os.path.exists(path):
                os.remove(path)


class NameHashes(unittest.TestCase):
    def test_every_listed_name_has_its_hash_and_nothing_else_is_listed(self):
        names = listed_names()
        self.assertEqual(sorted(sha(n) for n in names), sorted(c.NAME_HASHES))

    def test_okay_names_and_product_words(self):
        self.assertIn(sha(OKAY_NAME), c.OKAY_NAME_HASHES)
        self.assertNotIn(sha(OKAY_NAME), c.NAME_HASHES)
        self.assertEqual(c.SHIPPED_TEXT_OK_HASHES, {sha(PRODUCT_WORD)})
        self.assertTrue(c.SHIPPED_TEXT_OK_HASHES <= set(c.NAME_HASHES))

    def test_no_clear_name_in_the_script_or_in_this_test(self):
        for path in (SCRIPT, os.path.abspath(__file__)):
            with open(path, encoding="utf-8") as f:
                low = f.read().lower()
            for n in listed_names() + [OKAY_NAME]:
                self.assertTrue(n not in low, "%s spells a listed name out" % os.path.basename(path))

    def test_this_script_and_this_test_pass_their_own_check(self):
        for path in (SCRIPT, os.path.abspath(__file__)):
            with open(path, encoding="utf-8") as f:
                text = f.read()
            added = {i: line for i, line in enumerate(text.split("\n"), 1)}
            hits, skipped = c.check_added(os.path.basename(path), added, text)
            self.assertEqual([(h.line, h.rule) for h in hits], [], path)
            self.assertEqual(skipped, 0)


if __name__ == "__main__":
    unittest.main()
