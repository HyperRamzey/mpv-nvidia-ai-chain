#!/usr/bin/env python3
"""Prove that a set of C files changed only in comments and string literals.

Used after translating the VFX filter comments to English: comments and log text
are allowed to differ, code must not.

  ./verify_comments_only.py <baseline-dir> <current-dir> file1.c file2.h ...

Baseline is normally a pristine copy taken before the edit (or a `git show`
checkout). Checks per file:
  * code tokens, with comments stripped and whitespace collapsed, must be identical
  * the number of string literals must be unchanged
  * each string's printf conversion specifiers (%d %s %.2f ...) must be unchanged
  * character literals must be identical

Exit 0 = comments/strings only. Exit 1 = code changed, do not ship.

Note: the VFX filters embed CUDA kernel sources as adjacent C string literals, one
kernel line per literal. That is why literal *count* is part of the contract; keep
the 1:1 mapping when editing a comment inside a kernel string.
"""
import os
import re
import sys

SPEC = re.compile(r'%(?:[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|j|z|t|L)?[diouxXeEfgGaAcspn%])')


def tokens(src):
    """Split C source into ('code', text) / ('str', body) / ('chr', body); comments dropped."""
    out, i, n, code = [], 0, len(src), []

    def flush():
        if code:
            out.append(('code', ''.join(code)))
            code.clear()

    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            flush()
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            flush()
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif c in '"\'':
            flush()
            quote, j, buf = c, i + 1, []
            while j < n:
                if src[j] == '\\':
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if src[j] == quote:
                    break
                buf.append(src[j])
                j += 1
            out.append(('str' if quote == '"' else 'chr', ''.join(buf)))
            i = j + 1
        else:
            code.append(c)
            i += 1
    flush()
    return out


def norm_code(t):
    return re.sub(r'[ \t\r\n]+', ' ', t).strip()


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    base, cur, files = argv[1], argv[2], argv[3:]
    ok = True
    for f in files:
        bp, cp = os.path.join(base, f), os.path.join(cur, f)
        old = open(bp, encoding='utf-8', errors='replace').read()
        new = open(cp, encoding='utf-8', errors='replace').read()
        a, b = tokens(old), tokens(new)

        ca = [norm_code(t) for k, t in a if k == 'code' and norm_code(t)]
        cb = [norm_code(t) for k, t in b if k == 'code' and norm_code(t)]
        code_ok = ca == cb

        sa = [t for k, t in a if k == 'str']
        sb = [t for k, t in b if k == 'str']
        spec_ok = len(sa) == len(sb)
        bad = []
        if spec_ok:
            for i, (x, y) in enumerate(zip(sa, sb)):
                if SPEC.findall(x) != SPEC.findall(y):
                    spec_ok = False
                    bad.append((i, x, y))

        ch_ok = [t for k, t in a if k == 'chr'] == [t for k, t in b if k == 'chr']
        good = code_ok and spec_ok and ch_ok
        ok = ok and good
        print(f"{'OK  ' if good else 'FAIL'} {f:18s} code={code_ok} fmt={spec_ok} "
              f"chr={ch_ok} strings={len(sa)}->{len(sb)}")
        for i, x, y in bad[:3]:
            print(f"     spec mismatch #{i}: {x!r} -> {y!r}")
        if not code_ok:
            for x, y in zip(ca, cb):
                if x != y:
                    print(f"     first code diff:\n       OLD: {x[:160]}\n       NEW: {y[:160]}")
                    break

    print("\nRESULT:", "comments/strings only" if ok else "CODE CHANGED -- do not ship")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
