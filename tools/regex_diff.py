"""Differential test of zigregex against Python's `re`.

Generates random patterns over the supported syntax and random subjects,
runs every case through Python and through zig-out/bin/regex-probe, and
compares all match and group spans (as byte offsets) of a finditer scan.

    zig build probe
    uv run --no-project --python 3.14 python tools/regex_diff.py [-n 20000] [--seed 1]

Use the same Python that generated src/unicode_tables.zig.
"""

import argparse
import random
import re
import signal
import subprocess
import sys
import warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "zig-out" / "bin" / "regex-probe"

LITERALS = ["a", "b", "c", "A", "B", "é", "É", "ß", "ẞ", "中", "1", " ", "-", "_", "k", "K", "s", "ſ", "\\n", "\\.", "\\*", "\\\\", "\\x41", "\\u00e9", "\\t", "{", "}", "]"]
SUBJECT_CHARS = list("abcABk K1 -_.*\\{}]\n\t") + ["é", "É", "ß", "ẞ", "中", "ſ", "K", "٣"]
CLASS_ITEMS = ["a", "b", "c", "A", "é", "中", "-", "_", "1", "a-c", "A-C", "0-9", "\\w", "\\W", "\\d", "\\s", "\\S", "\\]", "\\\\", "\\n", "^", "k", "ſ", " "]
ESCAPES = ["\\w", "\\W", "\\d", "\\D", "\\s", "\\S"]
ASSERTS = ["^", "$", "\\b", "\\B", "\\A", "\\Z", "\\z"]
QUANTS = ["*", "+", "?", "*?", "+?", "??", "{2}", "{1,2}", "{0,2}", "{2,}", "{,2}", "{1,3}?", "{0,}?", "{3}?"]


class Gen:
    def __init__(self, rnd):
        self.r = rnd
        self.groups = 0
        self.closed = []
        self.named = []

    def alt(self, depth, fixed=False):
        n = self.r.choice([1, 1, 1, 2, 3])
        return "|".join(self.concat(depth, fixed) for _ in range(n))

    def concat(self, depth, fixed):
        n = self.r.randint(0 if not fixed else 1, 4)
        return "".join(self.piece(depth, fixed) for _ in range(n))

    def piece(self, depth, fixed):
        a = self.atom(depth, fixed)
        if not fixed and self.r.random() < 0.3:
            a += self.r.choice(QUANTS)
        elif fixed and self.r.random() < 0.15:
            a += "{2}"
        return a

    def atom(self, depth, fixed):
        r = self.r
        k = r.random()
        if k < 0.30:
            return r.choice(LITERALS)
        if k < 0.38:
            return "."
        if k < 0.50:
            items = "".join(r.choice(CLASS_ITEMS) for _ in range(r.randint(1, 3)))
            return "[" + ("^" if r.random() < 0.3 else "") + items + "]"
        if k < 0.58:
            return r.choice(ESCAPES)
        if k < 0.64 and not fixed:
            return r.choice(ASSERTS)
        if depth >= 3:
            return r.choice(LITERALS)
        if k < 0.80:
            kind = r.choice(["cap", "cap", "non", "named", "flags"])
            if kind in ("cap", "named"):
                self.groups += 1
                g = self.groups
                body = self.alt(depth + 1, fixed)
                self.closed.append(g)
                if kind == "named":
                    self.named.append(g)
                return f"(?P<g{g}>{body})" if kind == "named" else f"({body})"
            if kind == "flags":
                f = r.choice(["i", "m", "s", "-i", "i-s", "-m"])
                return f"(?{f}:{self.alt(depth + 1, fixed)})"
            return f"(?:{self.alt(depth + 1, fixed)})"
        if k < 0.90 and not fixed:
            look = r.choice(["?=", "?!", "?<=", "?<!"])
            if look in ("?<=", "?<!"):
                # Equal-width alternatives, as Python requires.
                return f"({look}{self.fixed_body()})"
            return f"({look}{self.alt(depth + 1)})"
        if self.closed and not fixed:
            if self.named and r.random() < 0.3:
                return f"(?P=g{r.choice(self.named)})"
            return f"\\{r.choice(self.closed)}"
        return r.choice(LITERALS)

    def fixed_body(self):
        width = self.r.randint(0, 3)
        alts = []
        for _ in range(self.r.choice([1, 1, 2])):
            alts.append("".join(self.single() for _ in range(width)))
        return "|".join(alts)

    def single(self):
        r = self.r
        k = r.random()
        if k < 0.5:
            return r.choice(LITERALS)
        if k < 0.65:
            return "."
        if k < 0.85:
            return r.choice(ESCAPES)
        items = "".join(r.choice(CLASS_ITEMS) for _ in range(r.randint(1, 3)))
        return "[" + ("^" if r.random() < 0.3 else "") + items + "]"


def gen_case(rnd):
    g = Gen(rnd)
    pat = g.alt(0)
    if rnd.random() < 0.1:
        pat = "(?" + rnd.choice(["i", "m", "s", "im", "is"]) + ")" + pat
    flags = "".join(f for f in "ims" if rnd.random() < 0.15) or "-"
    subj = "".join(rnd.choice(SUBJECT_CHARS) for _ in range(rnd.randint(0, 10)))
    return flags, pat, subj


class Timeout(Exception):
    pass


def _alarm(signum, frame):
    raise Timeout


def python_result(flags, pat, subj):
    fl = 0
    for c in flags:
        fl |= {"i": re.I, "m": re.M, "s": re.S}.get(c, 0)
    try:
        rx = re.compile(pat, fl)
    except (re.error, OverflowError, RecursionError):
        return "E"
    offs = [0]
    for ch in subj:
        offs.append(offs[-1] + len(ch.encode()))
    parts = []
    # Python has no step limit; sre checks for signals, so an alarm stops
    # catastrophic backtracking.
    signal.setitimer(signal.ITIMER_REAL, 2.0)
    try:
        for m in rx.finditer(subj):
            spans = []
            for gi in range(rx.groups + 1):
                s, e = m.span(gi)
                spans.append(f"{offs[s]},{offs[e]}" if s >= 0 else "-1,-1")
            parts.append(",".join(spans))
    except Timeout:
        return "T"
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    return ";".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--show", type=int, default=15)
    args = ap.parse_args()

    warnings.simplefilter("ignore", FutureWarning)  # "possible set difference" etc.
    rnd = random.Random(args.seed)
    cases = [gen_case(rnd) for _ in range(args.n)]
    stdin = "".join(f"{f}\t{p.encode().hex()}\t{s.encode().hex()}\n" for f, p, s in cases)
    out = subprocess.run([str(PROBE)], input=stdin.encode(), capture_output=True, check=True).stdout.decode()
    got = out.split("\n")[: len(cases)]

    signal.signal(signal.SIGALRM, _alarm)
    bad = invalid = limit = slow = 0
    for (f, p, s), z in zip(cases, got):
        py = python_result(f, p, s)
        if py == "T":
            slow += 1
            continue
        if z.endswith("X"):  # match limit, possibly after some matches
            limit += 1
            continue
        if py == "E":
            invalid += 1
        if py != z:
            bad += 1
            if bad <= args.show:
                print(f"flags={f} pattern={p!r} subject={s!r}\n  python: {py}\n  zig:    {z}")
    print(f"{len(cases)} cases, {invalid} invalid patterns, {limit} hit the match limit, "
          f"{slow} too slow in Python, {bad} mismatches")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
