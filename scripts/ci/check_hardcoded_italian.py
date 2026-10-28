#!/usr/bin/env python3
"""check_hardcoded_italian.py - source gate: user-facing Italian text goes through the String Catalog.

WHY. The app's development language is Italian and every user-facing string is translated in
QAudionApp/Localizable.xcstrings. A SwiftUI literal (Text("..."), Button("..."), .navigationTitle("...")) and
String(localized: "key", defaultValue: "...") reach that catalog. A plain Swift String does not: a message assigned
to a variable, returned from an enum, passed to a view that takes a String, or shown with Text(verbatim:) is
displayed in Italian whatever the language of the phone. Nothing else catches it, so this script reads the Swift
sources (stdlib only, any machine with Python 3) and fails when:

  1. a string literal that reads as Italian appears outside a localization API (the call it sits in is not
     String(localized:), LocalizedStringKey, NSLocalizedString, a SwiftUI view/modifier that takes a
     LocalizedStringKey, an App Intents title/description, ...);
  2. an Italian literal does sit in such an API but has no catalog entry (the literal is not a key of the
     catalog, or String(localized: "key", defaultValue: "...") names a key the catalog lacks, lacks a language,
     or whose Italian value differs from the defaultValue);
  3. an allowlist entry no longer matches anything (the list is for strings that are never shown to the user and
     must not collect dead lines; "pending:" entries are exempt).

Not checked: comments, log calls (print, RTLog.*, os_log, Logger, ...), code under `#if DEBUG`, `#Preview` and
PreviewProvider blocks, test targets, Package.swift. A literal that is Italian but internal (a protocol token, a
developer-only screen, a fixture) goes into scripts/ci/hardcoded_italian_allowlist.txt, one line each:

    relative/path.swift | exact literal as written in the source | reason

A reason that starts with "pending:" marks text that is waiting for another change to land; such an entry is not
reported when it stops matching, and is deleted once the text is localized.

USAGE   python3 -I scripts/ci/check_hardcoded_italian.py [--root DIR]
EXIT    0 clean | 1 a check failed | 2 cannot run
"""
import argparse
import json
import os
import re
import sys

SCAN_DIRS = ("QAudionApp", "QAudionEngine/Sources", "QAudionIntents", "QAudionPacketTunnel", "QAudionShare",
             "QAudionLiveActivity")
CATALOG = "QAudionApp/Localizable.xcstrings"
# Targets with a catalog of their own (the extensions bundle their own strings).
OWN_CATALOGS = {"QAudionShare/": "QAudionShare/Localizable.xcstrings",
                "QAudionLiveActivity/": "QAudionLiveActivity/Localizable.xcstrings"}
ALLOWLIST = "scripts/ci/hardcoded_italian_allowlist.txt"
LANGS = ("it", "en", "fr", "de", "es", "pt-BR")

# Words that are Italian and not English; two of them (or one plus an accented vowel) make a literal Italian.
STRONG = set("""il lo gli uno dei delle degli del della dal dalla dallo nel nella nei nelle sul sulla sui con per non che chi
sono stato stata stati essere hai ha ho mi ti ci si ne più già anche quando dopo prima senza questo questa questi queste
tuo tua tuoi suoi suo sua nuovo nuova nuovi errore impossibile riprova chiamata chiamate messaggio messaggi chiave chiavi
contatto contatti verifica verificato allegato connessione inviato ricevuto aperto chiuso attiva attivo disattiva scegli
seleziona apri chiudi invia annulla elimina salva disponibile mancante scaduto fallito riuscito gruppo voce fotocamera
tra fra ma se come dove cosa tutti tutto ogni altro altra altri nessun nessuna ancora ora mentre poi perché però oppure
sei siamo hanno può puoi vuoi devi dai usa usare aggiungi rimuovi vuoi fai fare sarà verrà viene stai sta sia siano
numero codice sicurezza dispositivo dispositivi impostazioni sessione server rete telefono utente impronta voce vocale
nome cognome password email mittente destinatario risposta richiesta riprovare attendi attendere completa completato
lui lei loro nostro vostro tuo mio mia miei mie dal dai dagli dalle alla alle allo agli ai al nei nelle negli""".split())
ACCENT = re.compile("[àèéìòùÀÈÉÌÒÙ]")
WORD = re.compile(r"[A-Za-zÀ-ÿ']+")

# Callees (last identifier of the call a literal is an argument of) whose literal arguments are localized.
LOCALIZING = {
    "LocalizedStringKey", "LocalizedStringResource", "NSLocalizedString", "loc",
    "Text", "Button", "Label", "Toggle", "Section", "TextField", "SecureField", "Picker", "NavigationLink", "Menu",
    "LabeledContent", "ProgressView", "Link", "ShareLink", "DisclosureGroup", "Stepper", "GroupBox", "Tab",
    "navigationTitle", "navigationBarTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue",
    "accessibilityIdentifier_", "help", "badge", "alert", "confirmationDialog", "searchable", "toolbarTitle",
    "Parameter", "IntentDescription", "AppShortcut", "DisplayRepresentation", "TypeDisplayRepresentation",
    "IntentDialog", "Summary", "ParameterSummary",
}
LOCALIZED_TYPES = re.compile(r"LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue|TypeDisplayRepresentation|IntentDescription")
LOG_CALLEE = re.compile(r"(^|\.)(print|debugPrint|NSLog|os_log|dump|fatalError|assert|assertionFailure|precondition|preconditionFailure|(RT|os|Live|Call|App|Debug)?[Ll]og\w*)(\.|$)")


def blank_interpolation(s):
    out, depth, i = [], 0, 0
    while i < len(s):
        if depth == 0 and s.startswith("\\(", i):
            depth = 1
            out.append(" ")
            i += 2
            continue
        if depth:
            if s[i] == "(":
                depth += 1
            elif s[i] == ")":
                depth -= 1
            i += 1
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def to_placeholders(s):
    """`\\(x)` -> %@ , the way the catalog writes interpolation in its keys."""
    out, depth, i = [], 0, 0
    while i < len(s):
        if depth == 0 and s.startswith("\\(", i):
            depth = 1
            out.append("%@")
            i += 2
            continue
        if depth:
            depth += (s[i] == "(") - (s[i] == ")")
            i += 1
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def unescape(s):
    """Swift escapes in a literal -> the characters the catalog stores (\\" -> ", \\n -> newline, \\u{2713} -> check)."""
    s = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(m.group(1), m.group(1)) if m.group(1) != "(" else m.group(0), s)


def catalog_text(raw):
    """A literal the way the catalog spells it: interpolation as %@, escapes resolved."""
    return unescape(to_placeholders(raw)).replace("%%", "%")


def norm_spec(s):
    return re.sub(r"%(?:\d+\$)?(?:lld|ld|lf|@|d|f)", "%@", s)


class Catalog:
    def __init__(self, strings):
        self.strings = strings
        self.keys_norm = {norm_spec(k): k for k in strings}
        self.italian = set()
        for k, v in strings.items():
            loc = v.get("localizations", {})
            it = loc.get("it", {}).get("stringUnit", {}).get("value")
            en = loc.get("en", {}).get("stringUnit", {}).get("value")
            for cand in (k, it):
                if cand and re.fullmatch(r"[a-z0-9_.]+", cand):
                    continue  # a dotted key, not text
                if cand and en and norm_spec(cand) != norm_spec(en):
                    self.italian.add(norm_spec(cand))

    def find(self, raw):
        text = catalog_text(raw)
        return self.strings.get(text) or self.strings.get(self.keys_norm.get(norm_spec(text), ""))

    def complete(self, entry):
        loc = entry.get("localizations", {})
        return [l for l in LANGS if not loc.get(l, {}).get("stringUnit", {}).get("value")]

    def it_value(self, entry):
        return entry.get("localizations", {}).get("it", {}).get("stringUnit", {}).get("value", "")


def looks_italian(raw, cat):
    t = catalog_text(raw)
    if norm_spec(t) in cat.italian:
        return True
    words = [w.lower() for w in WORD.findall(blank_interpolation(raw))]
    if not words:
        return False
    strong = sum(1 for w in words if w in STRONG)
    if strong >= 2:
        return True
    return strong >= 1 and len(words) >= 2 and bool(ACCENT.search(raw))


class Lit:
    __slots__ = ("raw", "line", "label", "callee", "line_prefix", "pos")

    def __init__(self, raw, line, label, callee, line_prefix, pos):
        self.raw, self.line, self.label, self.callee, self.line_prefix, self.pos = raw, line, label, callee, line_prefix, pos


def callee_before(code, idx):
    """Identifier chain right before the '(' at code[idx] ("RTLog.info", ".accessibilityLabel", "Text")."""
    j = idx
    while j > 0 and (code[j - 1].isalnum() or code[j - 1] in "_.?!"):
        j -= 1
    return code[j:idx].lstrip(".?!")


def tokenize(src):
    """Walks the source once; returns the string literals (with the call they sit in), and brace positions."""
    lits, braces = [], []
    stack = []  # [callee, current argument label, open ternaries] of each open '('
    code = []  # code characters only (comments and string bodies replaced), same length bookkeeping via index map
    i, n, line = 0, len(src), 1
    line_start = 0

    def label_before():
        k = len(code)
        text = "".join(code[max(0, k - 80):k])
        m = re.search(r"(\w+)\s*:\s*$", text)
        return m.group(1) if m else ""

    def read_string(i, line):
        """src[i] is the opening quote. Returns (raw, end_index, new_line)."""
        if src.startswith('"""', i):
            end = src.find('"""', i + 3)
            if end < 0:
                end = n
            raw = src[i + 3:end]
            return raw, end + 3, line + src.count("\n", i, end + 3)
        j = i + 1
        depth = 0
        while j < n:
            c = src[j]
            if depth == 0:
                if c == "\\":
                    if src.startswith("\\(", j):
                        depth = 1
                        j += 2
                        continue
                    j += 2
                    continue
                if c == '"' or c == "\n":
                    break
            else:
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                elif c == '"':
                    # nested string inside an interpolation
                    _, j2, _ = read_string(j, line)
                    j = j2
                    continue
            j += 1
        return src[i + 1:j], j + 1, line

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            line_start = i + 1
            code.append(c)
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            line += src.count("\n", i, j)
            i = j
            continue
        if c == "#" and re.match(r'#+"', src[i:i + 8]):
            m = re.match(r'(#+)"', src[i:i + 8])
            term = '"' + m.group(1)
            j = src.find(term, i + len(m.group(0)))
            j = n if j < 0 else j + len(term)
            line += src.count("\n", i, j)
            code.append('"')
            i = j
            continue
        if c == '"':
            label = label_before()
            raw, j, line2 = read_string(i, line)
            prefix = src[line_start:i]
            if not label and stack:
                label = stack[-1][1]  # ternary branch or array element: the label of its argument
            lits.append(Lit(raw, line, label, stack[-1][0] if stack else "", prefix, i))
            code.append('"')
            code.append('"')
            line = line2
            i = j
            continue
        if c == "(":
            callee = callee_before(src, i)
            if not callee and stack:
                stack.append([stack[-1][0], stack[-1][1], 0])  # a grouping parenthesis keeps the enclosing call
            else:
                stack.append([callee, "", 0])
            code.append(c)
        elif c == "[" and stack:
            stack.append([stack[-1][0], stack[-1][1], 0])  # an array or dictionary literal keeps the enclosing call
            code.append(c)
        elif c in ")]":
            if stack:
                stack.pop()
            code.append(c)
        elif c == "," and stack:
            stack[-1][1] = ""
            stack[-1][2] = 0
            code.append(c)
        elif c == "?" and stack and src[i - 1:i] == " " and src[i + 1:i + 2] == " ":
            stack[-1][2] += 1
            code.append(c)
        elif c == ":" and stack:
            if stack[-1][2] > 0:
                stack[-1][2] -= 1
            else:
                m = re.search(r"(\w+)\s*$", "".join(code[-60:]))
                if m:
                    stack[-1][1] = m.group(1)
            code.append(c)
        elif c in "{}":
            braces.append((i, c, line))
            code.append(c)
        else:
            code.append(c)
        i += 1
    return lits, braces


LOC_TYPE = re.compile(r"LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue|DisplayRepresentation|IntentDescription|IntentDialog")
TYPE_DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|open|final|indirect)\s+)*(?:struct|class|enum|actor|extension)\s+(\w+)", re.M)
FUNC_DECL = re.compile(r"\b(?:func\s+(\w+)|(init))\s*(?:<[^>]*>)?\s*\(", re.M)
PROP_DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|static)\s+)*(?:let|var)\s+(\w+)\s*:\s*([A-Za-z_.]+)", re.M)


def split_params(text):
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def function_body(src, start):
    """Text of the `{ ... }` body that follows the declaration ending at `start` (empty when there is none)."""
    j = src.find("{", start, min(len(src), start + 400))
    if j < 0:
        return ""
    depth, i = 0, j
    stop = min(len(src), j + 4000)
    while i < stop:
        depth += (src[i] == "{") - (src[i] == "}")
        i += 1
        if depth == 0:
            break
    return src[j:i]


def localizing_params(src, found, forwarded=None):
    """Adds (callee, argument label) pairs whose declared type is LocalizedStringKey / LocalizedStringResource.
    `found` maps callee -> set of labels ('' is an unlabeled parameter, '*' any)."""
    types = [(m.start(), m.group(1)) for m in TYPE_DECL.finditer(src)]
    # a String parameter or property that the file renders with LocalizedStringKey(name) takes a catalog key
    via_key = set(re.findall(r"LocalizedStringKey\(\s*(?:self\.)?(\w+)\s*\)", src))

    def owner(pos):
        name = ""
        for start, n in types:
            if start <= pos:
                name = n
            else:
                break
        return name

    for m in FUNC_DECL.finditer(src):
        name = m.group(1) or owner(m.start())
        i, depth = m.end(), 1
        while i < len(src) and depth:
            depth += (src[i] == "(") - (src[i] == ")")
            i += 1
        for prm in split_params(src[m.end():i - 1]):
            pm = re.match(r"\s*(\w+)(?:\s+(\w+))?\s*:\s*(?:@\w+\s+)*([^=]+)", prm)
            if pm and (LOC_TYPE.search(pm.group(3)) or (pm.group(2) or pm.group(1)) in via_key):
                label = "" if pm.group(1) == "_" else pm.group(1)
                found.setdefault(name, set()).add(label)
            elif pm and forwarded is not None and re.match(r"\s*String\b", pm.group(3)):
                forwarded.append((name, "" if pm.group(1) == "_" else pm.group(1), pm.group(2) or pm.group(1), function_body(src, i)))
    for m in PROP_DECL.finditer(src):
        if LOC_TYPE.search(m.group(2)) or m.group(1) in via_key:
            found.setdefault(owner(m.start()), set()).add(m.group(1))


def enclosing_declares_key(lines, lineno):
    """True when a declaration that encloses the literal (by indentation: a computed property, a function result,
    an array or tuple type) is typed LocalizedStringKey / LocalizedStringResource."""
    if not 0 < lineno <= len(lines):
        return False
    cur = len(lines[lineno - 1]) - len(lines[lineno - 1].lstrip())
    levels = 0
    for k in range(lineno - 2, max(-1, lineno - 80), -1):
        text = lines[k]
        if not text.strip():
            continue
        ind = len(text) - len(text.lstrip())
        if ind < cur:
            if LOC_TYPE.search(text) and re.search(r"\b(var|let|func|case)\b|->|:", text):
                return True
            if re.match(r"\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*(?:struct|class|enum|actor|extension)\b", text):
                return False
            cur = ind
            levels += 1
            if levels > 6:
                return False
    return False


def skip_ranges(src):
    """Character ranges of `#if DEBUG` bodies, `#Preview` and PreviewProvider blocks."""
    ranges = []
    # #if DEBUG ... (#else|#endif), with nesting
    stack = []
    pos = 0
    for line in src.split("\n"):
        s = line.strip()
        if s.startswith("#if "):
            cond = s[4:]
            stack.append((pos + len(line) + 1 if re.search(r"(^|[^!\w])DEBUG\b", cond) and "!DEBUG" not in cond else None))
        elif s.startswith("#else") or s.startswith("#elseif"):
            if stack and stack[-1] is not None:
                ranges.append((stack[-1], pos))
                stack[-1] = None
        elif s.startswith("#endif"):
            if stack:
                start = stack.pop()
                if start is not None:
                    ranges.append((start, pos))
        pos += len(line) + 1
    return ranges


def preview_ranges(src, braces):
    ranges = []
    for m in re.finditer(r"^\s*(#Preview\b|(?:\w+\s*:\s*)?PreviewProvider\b|.*:\s*PreviewProvider\b)", src, re.M):
        start = m.start()
        # first '{' after the match, then its matching '}'
        depth = 0
        began = False
        for (p, ch, _) in braces:
            if p < start:
                continue
            if ch == "{":
                depth += 1
                began = True
            else:
                depth -= 1
            if began and depth == 0:
                ranges.append((start, p))
                break
    return ranges


def in_ranges(pos, ranges):
    return any(a <= pos <= b for a, b in ranges)


def load_allowlist(root, problems):
    entries = {}
    path = os.path.join(root, ALLOWLIST)
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for no, line in enumerate(f, 1):
            s = line.rstrip("\n")
            if not s.strip() or s.lstrip().startswith("#"):
                continue
            parts = [p.strip() for p in s.split(" | ", 2)]
            if len(parts) != 3 or not all(parts):
                problems.append("%s:%d: expected `path | literal | reason`" % (ALLOWLIST, no))
                continue
            entries[(parts[0], parts[1])] = (no, parts[2])
    return entries


def source_files(root):
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [x for x in dirnames if not x.endswith("Tests") and x not in ("Tests", ".build", "Pods")]
            for fn in sorted(filenames):
                if fn.endswith(".swift") and fn != "Package.swift":
                    yield os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")


def check(root):
    problems = []
    try:
        with open(os.path.join(root, CATALOG), encoding="utf-8") as f:
            cat = Catalog(json.load(f)["strings"])
    except (OSError, ValueError, KeyError) as e:
        print("cannot read %s: %s" % (CATALOG, e), file=sys.stderr)
        return None
    own_cats = {}
    for prefix, rel_cat in OWN_CATALOGS.items():
        path = os.path.join(root, rel_cat)
        if os.path.isfile(path):
            try:
                with open(path, encoding="utf-8") as f:
                    own_cats[prefix] = Catalog(json.load(f)["strings"])
            except (OSError, ValueError, KeyError) as e:
                print("cannot read %s: %s" % (rel_cat, e), file=sys.stderr)
                return None
    main_cat = cat
    allow = load_allowlist(root, problems)
    used = set()
    sources = {}
    loc_params = {}
    forwarded = []
    for rel in source_files(root):
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                sources[rel] = f.read()
        except (OSError, UnicodeDecodeError) as e:
            problems.append("%s cannot be read: %s" % (rel, e))
            continue
        localizing_params(sources[rel], loc_params, forwarded)
    # a String parameter handed on to something that localizes it (section(_ title: String) { Header(title) })
    for _ in range(3):
        grew = False
        for name, label, inner, body in forwarded:
            if label in loc_params.get(name, ()):
                continue
            for callee, arg_label, arg in re.findall(r"\b(\w+)\(\s*(?:(\w+):\s*)?(\w+)\s*[,)]", body):
                if arg == inner and (arg_label if arg_label else "") in loc_params.get(callee, ()):
                    loc_params.setdefault(name, set()).add(label)
                    grew = True
                    break
        if not grew:
            break
    for rel, src in sources.items():
        cat = next((c for prefix, c in own_cats.items() if rel.startswith(prefix)), main_cat)
        lits, braces = tokenize(src)
        src_lines = src.split("\n")
        skips = skip_ranges(src) + preview_ranges(src, braces)
        last_key = None
        for lit in lits:
            if in_ranges(lit.pos, skips):
                continue
            callee = lit.callee.split(".")[-1] if lit.callee else ""
            where = "%s:%d" % (rel, lit.line)
            if lit.label in ("localized", "defaultValue") and callee == "String":
                # String(localized: "key", defaultValue: "text"): the key has to be in the catalog with every language
                # and the defaultValue has to be the catalog's Italian value.
                if lit.label == "localized":
                    last_key = None
                    entry = cat.find(lit.raw)
                    if entry is None:
                        problems.append("%s: String(localized:) key not in the catalog: %r" % (where, lit.raw))
                    else:
                        last_key = (lit.raw, entry)
                        gaps = cat.complete(entry)
                        if gaps:
                            problems.append("%s: catalog entry %r lacks %s" % (where, lit.raw, ", ".join(gaps)))
                elif last_key is not None:
                    want = norm_spec(cat.it_value(last_key[1]).replace("%%", "%"))
                    have = norm_spec(catalog_text(lit.raw))
                    if want and have != want:
                        problems.append("%s: defaultValue differs from the Italian catalog value of %r: %r" % (where, last_key[0], lit.raw))
                continue
            if lit.label in ("comment", "phrases") or not looks_italian(lit.raw, cat):
                continue  # Siri phrases live in AppShortcuts.strings, which has its own gate
            if LOG_CALLEE.search(lit.callee or ""):
                continue
            text = lit.raw
            if (rel, text) in allow:
                used.add((rel, text))
                continue
            declared_localized = bool(LOCALIZED_TYPES.search(lit.line_prefix))
            if lit.label == "verbatim":
                problems.append("%s: Italian text shown verbatim, not localized: %r" % (where, text))
                continue
            takes_key = lit.label in loc_params.get(callee, ()) or ("" in loc_params.get(callee, ()) and not lit.label)
            if callee in LOCALIZING or declared_localized or takes_key or enclosing_declares_key(src_lines, lit.line):
                entry = cat.find(text)
                if entry is None:
                    problems.append("%s: Italian text has no catalog entry: %r" % (where, text))
                else:
                    gaps = cat.complete(entry)
                    if gaps:
                        problems.append("%s: catalog entry %r lacks %s" % (where, text, ", ".join(gaps)))
                continue
            problems.append("%s: Italian text outside a localization API: %r" % (where, text))
    for (rel, text), (no, reason) in sorted(allow.items()):
        if (rel, text) not in used and not reason.startswith("pending:"):
            problems.append("%s:%d: allowlist entry matches nothing any more: %s | %r" % (ALLOWLIST, no, rel, text))
    return problems


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    args = ap.parse_args(argv)
    problems = check(args.root)
    if problems is None:
        return 2
    if problems:
        print("hard-coded Italian text: %d problem(s)" % len(problems), file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        print("Route user-facing text through String(localized: \"key\", defaultValue: \"...\") and add the "
              "catalog entry; internal text goes into %s." % ALLOWLIST, file=sys.stderr)
        return 1
    print("OK: no hard-coded Italian text outside the String Catalog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
