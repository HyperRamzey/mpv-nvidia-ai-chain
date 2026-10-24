#!/usr/bin/python3

"""
Usage: find-deps.py <binary> [<binary> ...]

Finds (pacman/ALPM) dependencies for a binary or set of binaries based
on dynamically linked libraries.

Self-contained: uses `pacman -Qqo` for ownership and one `pacman -Qi` dump
for the dependency graph. Does not need pactree / pacman-contrib, which are
not guaranteed to be installed at package() time.
"""

import sys
import os
import subprocess
import re


def subprocess_get_lines(args, fail_okay=False):
    env = dict(os.environ)
    env["LC_ALL"] = "C"  # pacman -Qi field names must stay parseable
    try:
        output = subprocess.check_output(args, env=env, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as e:
        if fail_okay:
            output = e.output
        else:
            raise
    return output.decode().splitlines()


for var in ("LD_LIBRARY_PATH", "LD_PRELOAD"):  # otherwise fakeroot will interfere
    os.environ.pop(var, None)

# Get the filenames of the libs we need
ldd_output = subprocess_get_lines(["ldd"] + sys.argv[1:])
regex = re.compile(r" => (.*) \(0x[0-9a-f]+\)$")
libs = set(match.group(1) for match in map(regex.search, ldd_output) if match)

# Figure out which packages own them
owners = set()
for lib in sorted(libs):
    owners.update(subprocess_get_lines(
        ["pacman", "--query", "--owns", "--quiet", lib], fail_okay=True))
owners.discard("")

# Dump every installed package once and build the dependency graph locally.
# `pacman -Qi` separates records with a blank line and starts each field with
# a word followed by ':'; continuation lines are indented.
field_re = re.compile(r"^([A-Z][A-Za-z ]*?)\s*:\s*(.*)$")
graph = {}
name = None
field = None
for line in subprocess_get_lines(["pacman", "--query", "--info"]):
    if not line.strip():
        name = field = None
        continue
    m = field_re.match(line)
    if m:
        field = m.group(1)
        value = m.group(2).strip()
        if field == "Name":
            name = value
            graph.setdefault(name, set())
        elif field == "Depends On" and name:
            graph[name].update(v for v in value.split() if v and v != "None")
        continue
    if field == "Depends On" and name:  # wrapped continuation line
        graph[name].update(v for v in line.split() if v and v != "None")

def deps_of(pkg):
    d = set()
    for tok in graph.get(pkg, ()):
        d.add(re.split(r"[<>=]", tok, maxsplit=1)[0])
    return d

# Everything reachable from another owner is redundant: pacman pulls it in
# anyway. That is what pactree --unique used to prune.
def closure(start):
    seen = set()
    stack = list(start)
    while stack:
        pkg = stack.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        stack.extend(deps_of(pkg))
    return seen

needed = set(owners)
for pkg in owners:
    needed.difference_update(closure(deps_of(pkg)) - {pkg})

print(" ".join(sorted(needed)))
