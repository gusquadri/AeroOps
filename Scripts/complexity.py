#!/usr/bin/env python3
import csv
import subprocess
import sys

from changed_lines import is_added

MAX_CCN = 6
MAX_LINES = 40


def functions(files):
    out = subprocess.run(["lizard", "--csv", *files], capture_output=True, text=True, check=False).stdout
    return list(csv.reader(out.splitlines()))


def problems(row):
    ccn, length = int(row[1]), int(row[4])
    found = [f"CCN {ccn} > {MAX_CCN}"] if ccn > MAX_CCN else []
    return found + ([f"{length} lines > {MAX_LINES}"] if length > MAX_LINES else [])


def touched(row):
    return is_added(row[6], int(row[9]), int(row[10]))


def flagged(rows, added):
    over = [row for row in rows if problems(row)]
    return [row for row in over if touched(row)] if added else over


def main(argv):
    added = argv[:1] == ["--added"]
    rows = flagged(functions(argv[added:]), added)
    for row in rows:
        print(f"FAIL {row[6]}:{row[9]}: {row[7]}: {', '.join(problems(row))}")
    print(f"complexity: {len(rows)} function(s) over the limits")
    return 1 if rows else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
