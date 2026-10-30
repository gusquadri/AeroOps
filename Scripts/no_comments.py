#!/usr/bin/env python3
import io
import re
import sys
import tempfile
import tokenize
from pathlib import Path

from changed_lines import is_added

ALLOWED = re.compile(r"^(upstream|spec|legal): \S+ — \S.*$")
SKIPPED_DIRS = {"node_modules", ".git", "dist", "build", ".venv", "venv", "target", "__pycache__"}
JS = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}
CLIKE = JS | {".go", ".rs", ".java", ".kt", ".swift", ".c", ".h", ".cc", ".cpp", ".cxx", ".hh", ".hpp"}
SUFFIXES = {".py", ".sh", ".rb"} | CLIKE
NESTED = {".rs", ".swift"}
TICK_RAW = {".go"}
RUST = {".rs"}
HASH_AFTER = " \t\n\r;|&()<>"
REGEX_AFTER = "(,=:[!&|?{;+-*%~^"
REGEX_KEYWORDS = {
    "return", "typeof", "case", "in", "of", "delete", "void",
    "throw", "new", "yield", "await", "instanceof", "else", "do",
}
RUST_CHAR = re.compile(r"'(?:\\(?:u\{[0-9a-fA-F]{1,6}\}|x[0-9a-fA-F]{2}|.)|[^\\'\n])'")
SWIFT_DOC = re.compile(r"^///(?!/)")
TRIPLE_SLASH = re.compile(r"^/// <(reference|amd-module|amd-dependency)\b[^>]*/>\s*$")
DIRECTIVES = {
    ".go": re.compile(r"^//(go:\w+|line \S|export \w|\s*\+build )"),
    ".rb": re.compile(r"^#\s*(-\*-\s*)?(frozen_string_literal|shareable_constant_value|warn_indent|warn_past_scope):"),
    ".swift": SWIFT_DOC,
    **dict.fromkeys(JS, TRIPLE_SLASH),
}

CASES = [
    ("trail.js", "let x = 1; // leftover\n", True),
    ("block.ts", "let x = 1;\n/*\n * hidden\n */\n", True),
    ("dead.js", "// const x = 1;\nlet y = 2;\n", True),
    ("str.js", "const a = 'http://x';\nconst b = 'not /* a comment */';\n", False),
    ("tmpl.js", "const a = `hello // still a string`;\n", False),
    ("tmpl-expr.js", "const a = `x ${1 /* bad */} y`;\n", True),
    ("str.py", "s = 'hello # not'\nprint(s)\n", False),
    ("ok.py", "# upstream: https://github.com/org/lib/issues/1234 — returns UTC without offset\nprint(1)\n", False),
    ("ok-line.js", "let x = 1;\n// upstream: https://example.com/issue/1 — vendor drops tz\n", False),
    ("noqa.py", "x = 1  # noqa\n", True),
    ("type.py", "x = 1  # type: ignore\n", True),
    ("ts-ignore.ts", "// @ts-ignore\nconst x = 1;\n", True),
    ("eslint.js", "// eslint-disable-next-line no-alert\nalert(1);\n", True),
    ("shebang.py", "#!/usr/bin/env python3\nprint(1)\n", False),
    ("encoding.py", "# -*- coding: utf-8 -*-\nprint(1)\n", False),
    ("block-ok.c", "int x = 1; /* upstream: https://example.com/bug — wrap is inverted */\n", False),
    ("count.sh", 'n=${#arr[@]}\necho "$n"\n', False),
    ("trail.sh", "echo hi # leftover\n", True),
    ("regex.js", "const re = /\\/\\//;\nconst cls = /[/]/;\n", False),
    ("regex-trail.js", "const re = /a/g; // leftover\n", True),
    ("div.js", "const half = total / 2; // leftover\n", True),
    ("module.mjs", "// leftover\nexport const x = 1;\n", True),
    ("lifetime.rs", "fn f(x: &'static str) -> usize { x.len() }\n// leftover\n", True),
    ("char.rs", "let q = '\"'; let s = \"// not a comment\";\n", False),
    ("embed.go", "//go:embed hello.txt\nvar s string\n", False),
    ("nolint.go", "x := 1 //nolint\n", True),
    ("ref.ts", '/// <reference types="vite/client" />\nexport {}\n', False),
    ("frozen.rb", "# frozen_string_literal: true\nputs 1\n", False),
    ("doc.swift", "/// Signs with the key.\nfunc f() {}\n", False),
    ("trail.swift", "func f() {} // leftover\n", True),
    ("banner.swift", "// MARK: - Run\nlet x = 1\n", True),
    ("block-doc.swift", "/** Hidden. */\nlet x = 1\n", True),
]


def line_at(source, index):
    return source.count("\n", 0, index) + 1


def line_end(source, start):
    found = source.find("\n", start)
    return len(source) if found < 0 else found


def line_starts(source):
    starts = [0]
    for index, char in enumerate(source):
        if char == "\n":
            starts.append(index + 1)
    return starts


def at_line_start(source, index):
    return index == 0 or source[index - 1] == "\n"


def is_url_slash(source, index):
    return index > 0 and source[index - 1] == ":"


def can_hash(source, index, always):
    if always:
        return True
    return index == 0 or source[index - 1] in HASH_AFTER


def skip_quoted(source, start, escaped):
    quote = source[start]
    index = start + 1
    while index < len(source):
        char = source[index]
        if escaped and char == "\\":
            index += 2
            continue
        if char == quote:
            return index + 1
        index += 1
    return len(source)


def skip_raw_tick(source, start):
    found = source.find("`", start + 1)
    return len(source) if found < 0 else found + 1


def skip_rust_raw(source, start):
    index = start + 1
    while index < len(source) and source[index] == "#":
        index += 1
    if index >= len(source) or source[index] != '"':
        return None
    marker = '"' + source[start + 1 : index]
    found = source.find(marker, index + 1)
    return len(source) if found < 0 else found + len(marker)


def skip_rust_char(source, start):
    match = RUST_CHAR.match(source, start)
    return match.end() if match else start + 1


def skip_block(source, start, nested):
    index = start + 2
    depth = 1
    while index < len(source) and depth:
        pair = source[index : index + 2]
        if nested and pair == "/*":
            depth += 1
            index += 2
            continue
        if pair == "*/":
            depth -= 1
            index += 2
            continue
        index += 1
    return index


def skip_template_inner_noise(source, index, spans):
    if source.startswith("//", index):
        end = line_end(source, index)
        spans.append((index, end))
        return end
    if source.startswith("/*", index):
        end = skip_block(source, index, False)
        spans.append((index, end))
        return end
    if source[index] in "'\"":
        return skip_quoted(source, index, True)
    return None


def step_template_outer(source, index):
    char = source[index]
    if char == "`":
        return index + 1, 0, True
    if char == "\\":
        return index + 2, 0, False
    if source.startswith("${", index):
        return index + 2, 1, False
    return index + 1, 0, False


def step_template_inner(source, index, expr, spans):
    if source.startswith("${", index):
        return index + 2, expr + 1, False
    skipped = skip_template_inner_noise(source, index, spans)
    if skipped is not None:
        return skipped, expr, False
    if source[index] == "}":
        return index + 1, expr - 1, False
    if source[index] == "`":
        return skip_template(source, index, spans), expr, False
    return index + 1, expr, False


def skip_template(source, start, spans):
    index = start + 1
    expr = 0
    while index < len(source):
        if expr == 0:
            index, expr, done = step_template_outer(source, index)
        else:
            index, expr, done = step_template_inner(source, index, expr, spans)
        if done:
            return index
    return len(source)


def previous_significant(source, index):
    index -= 1
    while index >= 0 and source[index] in " \t\r\n":
        index -= 1
    return index


def word_ending_at(source, end):
    start = end
    while start >= 0 and (source[start].isalnum() or source[start] in "_$"):
        start -= 1
    return source[start + 1 : end + 1]


def regex_can_start(source, index):
    prev = previous_significant(source, index)
    if prev < 0 or source[prev] in REGEX_AFTER:
        return True
    return word_ending_at(source, prev) in REGEX_KEYWORDS


def regex_class_state(char, in_class):
    if char == "[":
        return True
    if char == "]":
        return False
    return in_class


def regex_end(source, start):
    end = line_end(source, start)
    index = start + 1
    in_class = False
    while index < end:
        char = source[index]
        if char == "\\":
            index += 2
            continue
        if char == "/" and not in_class:
            return index + 1
        in_class = regex_class_state(char, in_class)
        index += 1
    return None


def skip_regex(source, index, suffix):
    if suffix not in JS or source[index] != "/":
        return None
    if not regex_can_start(source, index):
        return None
    return regex_end(source, index)


def ruby_begin_here(source, start):
    if not at_line_start(source, start) or not source.startswith("=begin", start):
        return False
    rest = start + 6
    return rest >= len(source) or source[rest] in "\n \t"


def ruby_end_here(source, found):
    end_at = found + 1
    after = end_at + 4
    if after >= len(source) or source[after] in "\n \t":
        return line_end(source, end_at)
    return None


def ruby_block_end(source, start):
    if not ruby_begin_here(source, start):
        return None
    pos = start + 6
    while pos < len(source):
        found = source.find("\n=end", pos)
        if found < 0:
            return len(source)
        done = ruby_end_here(source, found)
        if done is not None:
            return done
        pos = found + 5
    return len(source)


def next_ruby_block(source, index):
    end = ruby_block_end(source, index)
    if end is None:
        return None
    return end, [(index, end)]


def next_hash_line(source, index, always):
    char = source[index]
    if char in "'\"":
        return skip_quoted(source, index, escaped=(char == '"')), []
    if char == "#" and can_hash(source, index, always):
        end = line_end(source, index)
        return end, [(index, end)]
    return index + 1, []


def next_hash(source, index, always, ruby_blocks):
    if ruby_blocks:
        block = next_ruby_block(source, index)
        if block is not None:
            return block
    return next_hash_line(source, index, always)


def skip_tick_string(source, index, suffix, spans):
    if suffix in JS:
        return skip_template(source, index, spans)
    if suffix in TICK_RAW:
        return skip_raw_tick(source, index)
    return None


def skip_rust_literal(source, index):
    char = source[index]
    if char == '"':
        return skip_quoted(source, index, True)
    if char == "'":
        return skip_rust_char(source, index)
    if char == "r":
        return skip_rust_raw(source, index)
    return None


def skip_clike_string(source, index, suffix, spans):
    if suffix in RUST:
        return skip_rust_literal(source, index)
    char = source[index]
    if char in "'\"":
        return skip_quoted(source, index, True)
    if char == "`":
        return skip_tick_string(source, index, suffix, spans)
    return None


def clike_comment_end(source, index, suffix):
    pair = source[index : index + 2]
    if pair == "//" and not is_url_slash(source, index):
        return line_end(source, index)
    if pair == "/*":
        return skip_block(source, index, suffix in NESTED)
    return None


def next_clike(source, index, suffix):
    extra = []
    skipped = skip_clike_string(source, index, suffix, extra)
    if skipped is not None:
        return skipped, extra
    end = clike_comment_end(source, index, suffix)
    if end is not None:
        return end, [(index, end)]
    regex = skip_regex(source, index, suffix)
    if regex is not None:
        return regex, []
    return index + 1, []


def next_shell(source, index):
    return next_hash(source, index, False, False)


def next_ruby(source, index):
    return next_hash(source, index, True, True)


def collect_spans(source, step):
    spans = []
    index = 0
    while index < len(source):
        index, found = step(source, index)
        spans.extend(found)
    return spans


def python_spans(source):
    read = io.BytesIO(source.encode("utf-8", errors="replace")).readline
    starts = line_starts(source)
    spans = []
    try:
        for tok in tokenize.tokenize(read):
            if tok.type != tokenize.COMMENT:
                continue
            begin = starts[tok.start[0] - 1] + tok.start[1]
            end = starts[tok.end[0] - 1] + tok.end[1]
            spans.append((begin, end))
    except tokenize.TokenError:
        return spans
    return spans


def spans_for(suffix, source):
    if suffix == ".py":
        return python_spans(source)
    if suffix == ".sh":
        return collect_spans(source, next_shell)
    if suffix == ".rb":
        return collect_spans(source, next_ruby)
    if suffix in CLIKE:

        def step(src, index):
            return next_clike(src, index, suffix)

        return collect_spans(source, step)
    return []


def strip_ruby_begin(raw):
    body = raw[6:]
    stripped = body.rstrip()
    if stripped.endswith("=end"):
        return stripped[:-4]
    return body


def strip_hash(raw):
    if raw.startswith("#"):
        return raw[1:]
    return raw


def strip_delimiters(raw):
    if raw.startswith("/*") and raw.endswith("*/"):
        return raw[2:-2]
    if raw.startswith("//"):
        return raw[2:]
    if raw.startswith("=begin"):
        return strip_ruby_begin(raw)
    return strip_hash(raw)


def is_directive(raw, suffix):
    pattern = DIRECTIVES.get(suffix)
    return pattern is not None and "\n" not in raw and pattern.match(raw) is not None


def is_exempt(raw, start, source, suffix):
    if is_directive(raw, suffix):
        return True
    if raw.startswith("#!") and line_at(source, start) == 1:
        return True
    line = line_at(source, start)
    encoded = raw.encode("utf-8", errors="replace")
    return line <= 2 and tokenize.cookie_re.match(encoded) is not None


def numbered_comment_lines(raw):
    found = []
    pos = 0
    for line in raw.splitlines(keepends=True):
        text = line.rstrip("\r\n").strip()
        if text:
            found.append((pos, text))
        pos += len(line)
    return found


def violations_from_span(path, source, start, end):
    raw = source[start:end]
    if is_exempt(raw, start, source, path.suffix):
        return []
    body = strip_delimiters(raw).strip()
    if ALLOWED.match(body) and "\n" not in raw:
        return []
    return [
        (path, line_at(source, start + offset), text)
        for offset, text in numbered_comment_lines(raw)
    ]


def violations_in(path):
    source = path.read_text(encoding="utf-8", errors="replace")
    spans = spans_for(path.suffix, source)
    found = []
    for start, end in spans:
        found.extend(violations_from_span(path, source, start, end))
    return found


def is_source(path, base):
    if not path.is_file() or path.suffix not in SUFFIXES:
        return False
    return not SKIPPED_DIRS & set(path.relative_to(base).parts)


def source_files(root):
    base = Path(root)
    if base.is_file():
        return [base] if base.suffix in SUFFIXES else []
    return [path for path in base.rglob("*") if is_source(path, base)]


def self_check():
    failed = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, source, must_fail in CASES:
            path = root / name
            path.write_text(source)
            found = scan_roots([path])
            bad = bool(found)
            mark = "ok" if bad == must_fail else "FAIL"
            if bad != must_fail:
                failed.append(name)
            print(f"{mark} {name} ({len(found)} violation(s))")
            for _, number, text in found:
                print(f"  {number}: {text}")
    print(f"self-check: {len(failed)} failed")
    return 1 if failed else 0


def scan_roots(roots):
    return [
        item
        for root in roots
        for path in source_files(root)
        for item in violations_in(path)
    ]


def report(found):
    for path, number, text in found:
        print(f"{path}:{number}: {text}")
    print(f"comments: {len(found)} violation(s)")
    return 1 if found else 0


def only_added(found):
    return [(path, number, text) for path, number, text in found if is_added(path, number)]


def check(roots, added):
    missing = [root for root in roots if not Path(root).exists()]
    if missing:
        print(f"comments: path not found: {', '.join(missing)}")
        return 2
    found = scan_roots(roots)
    return report(only_added(found) if added else found)


def main(argv):
    if argv == ["--self-check"]:
        return self_check()
    added = argv[:1] == ["--added"]
    return check(argv[added:] or ["."], added)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
