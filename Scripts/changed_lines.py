import re
import subprocess
from functools import cache

HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", re.MULTILINE)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False).stdout


def hunk_lines(diff):
    lines = set()
    for match in HUNK.finditer(diff):
        start = int(match[1])
        lines.update(range(start, start + int(match[2] or 1)))
    return lines


@cache
def added_lines(path):
    if not git("ls-files", "--", path).strip():
        return None
    return frozenset(hunk_lines(git("diff", "-U0", "HEAD", "--", path)))


def is_added(path, first, last=None):
    lines = added_lines(str(path))
    return lines is None or not lines.isdisjoint(range(first, (last or first) + 1))
