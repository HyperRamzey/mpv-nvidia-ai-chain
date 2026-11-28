#!/usr/bin/env bash
# Copy the project's sources to the clipboard, each one annotated with its path.
#
#   scripts/grab-sources.sh                    # code + docs + build files (default)
#   scripts/grab-sources.sh --stat             # show what would be copied, copy nothing
#   scripts/grab-sources.sh --code             # skip the prose (*.md)
#   scripts/grab-sources.sh --docs             # prose only
#   scripts/grab-sources.sh --data             # also include *.json/*.yml data files
#   scripts/grab-sources.sh --fork             # also include the mpv fork's changed files
#   scripts/grab-sources.sh 'shaders/*'        # restrict to path patterns
#   scripts/grab-sources.sh --numbers          # prefix every line with its line number
#   scripts/grab-sources.sh --out bundle.txt   # write a file instead of the clipboard
#
# Selection is from `git ls-files`, so nothing untracked and nothing under build/ is
# ever included — `git add` a new file before bundling it. --fork adds the files the
# mpv fork reports as modified or added against its own HEAD, so a reviewer sees the
# local C changes without pasting all of mpv; the default is the makepkg build tree
# (build/makepkg/mpv-dovi-vfx-git/src/mpv), not the older build/src/mpv staging
# checkout, which lags the shipped patch. Binaries and files over 2 MB are skipped
# with a note on stderr. Order is stable: shaders, scripts, tests, tools, docs, the
# filter patch, then build/package files, then prose.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

max_bytes=$((2 * 1024 * 1024))
out=""
to_clipboard=1
numbers=0
stat_only=0
mode="all"
data=0
fork=0
fork_dir=""
patterns=()

while (($#)); do
    case "$1" in
        --stat) stat_only=1 ;;
        --code) mode="code" ;;
        --docs) mode="docs" ;;
        --data) data=1 ;;
        --fork) fork=1 ;;
        --fork-dir) shift; fork_dir="${1:?--fork-dir needs a path}"; fork=1 ;;
        --numbers) numbers=1 ;;
        --out) shift; out="${1:?--out needs a path}"; to_clipboard=0 ;;
        -h | --help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            exit 2
            ;;
        *) patterns+=("$1") ;;
    esac
    shift
done

# Extension sets. glsl and lua are the chain itself; c/h and patch are the mpv
# fork; sh and py are tooling; conf and the no-extension package files are build
# configuration a reviewer needs next to the code.
code_exts=(glsl lua c h sh py conf patch)
doc_exts=(md)
data_exts=(json yml yaml)
# Files with no extension that still belong to the project.
name_allowlist=(PKGBUILD mpv.install LICENSE LICENSE.GPL LICENSE.LGPL Copyright NOTICE)

# What a path must match to be selected, given the mode. Built once.
wanted=()
case "$mode" in
    code)
        for e in "${code_exts[@]}"; do wanted+=("*.$e"); done
        ;;
    docs)
        for e in "${doc_exts[@]}"; do wanted+=("*.$e"); done
        ;;
    *)
        for e in "${code_exts[@]}" "${doc_exts[@]}"; do wanted+=("*.$e"); done
        ;;
esac
if ((data)); then
    for e in "${data_exts[@]}"; do wanted+=("*.$e"); done
fi

# Order groups explicitly rather than alphabetically: a reviewer reads the shader,
# then the script that drives it, then the tests, then the docs, then the fork patch.
order_groups=(
    "shaders/"
    "scripts/"
    "tests/"
    "tools/"
    "docs/"
    "vfx-filters.patch"
    "PKGBUILD"
    "input.conf"
    "ai.conf"
    "find-deps.py"
    "mpv.install"
    "README.md"
    ".github/"
)

mapfile -t tracked < <(git ls-files)

in_group() {
    # Is $1 in the same order group as $2? Exact file, or under the directory.
    local path="$1" group="$2"
    case "$group" in
        */) [[ "${path#"$group"}" != "$path" ]] ;;
        *) [[ "$path" == "$group" ]] ;;
    esac
}

matches_ext() {
    local path="$1" e
    for e in "${wanted[@]}"; do
        # shellcheck disable=SC2053  # right-hand side is a pattern on purpose
        [[ "$path" == $e ]] && return 0
    done
    if [[ "$mode" != "code" ]]; then
        local base="${path##*/}"
        for allowed in "${name_allowlist[@]}"; do
            [[ "$base" == "$allowed" ]] && return 0
        done
    fi
    return 1
}

declare -a picked=()
for group in "${order_groups[@]}"; do
    for f in "${tracked[@]}"; do
        in_group "$f" "$group" || continue
        matches_ext "$f" || continue
        picked+=("$f")
    done
done
# Anything tracked that no group claims still belongs in the bundle; dropping it
# silently would hand a reviewer a tree that looks complete and is not.
for f in "${tracked[@]}"; do
    claimed=0
    for group in "${order_groups[@]}"; do
        if in_group "$f" "$group"; then
            claimed=1
            break
        fi
    done
    ((claimed)) && continue
    matches_ext "$f" && picked+=("$f")
done

# Optional pattern restriction, matched with the shell's own globbing.
if ((${#patterns[@]})); then
    filtered=()
    for f in "${picked[@]}"; do
        for p in "${patterns[@]}"; do
            # shellcheck disable=SC2053
            [[ "$f" == $p ]] && filtered+=("$f") && break
        done
    done
    picked=("${filtered[@]}")
fi

# --fork: the mpv tree keeps its own git history, so its "sources" are the files
# it reports as modified or added against HEAD. Whole mpv is far too big to paste.
fork_head=""
declare -a fork_picked=()
if ((fork)); then
    if [[ -z "$fork_dir" ]]; then
        for cand in "$root/../build/makepkg/mpv-dovi-vfx-git/src/mpv" \
                    "$root/../build/src/mpv"; do
            if [[ -d "$cand" ]]; then
                fork_dir=$cand
                break
            fi
        done
    fi
    fork_dir=${fork_dir:-"$root/../build/src/mpv"}
    if [[ ! -d "$fork_dir" ]]; then
        echo "fork dir not found: $fork_dir" >&2
        exit 2
    fi
    fork_head=$(git -C "$fork_dir" rev-parse --short HEAD 2>/dev/null || echo "?")
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        status=${line:0:2}
        path=${line:3}
        [[ "$status" == *D* ]] && continue
        # patch(1) backups and rejects are not source and only confuse a reviewer.
        case "$path" in *.orig | *.rej) continue ;; esac
        [[ -f "$fork_dir/$path" ]] || continue
        fork_picked+=("$path")
    done < <(git -C "$fork_dir" status --porcelain)
fi

# Drop unreadable, binary and oversized files, saying so on stderr. final holds
# "display|realpath" pairs so fork files can be labelled with their tree.
final=()
skipped=0
add_final() {
    local display="$1" real="$2"
    if [[ ! -r "$real" ]]; then
        echo "skip (unreadable): $display" >&2
        skipped=$((skipped + 1))
        return
    fi
    local size
    size=$(wc -c <"$real")
    if ((size > max_bytes)); then
        echo "skip (over 2 MB): $display ($size bytes)" >&2
        skipped=$((skipped + 1))
        return
    fi
    if ! grep -qI '' "$real" 2>/dev/null; then
        echo "skip (binary): $display" >&2
        skipped=$((skipped + 1))
        return
    fi
    final+=("$display|$real")
}

for f in "${picked[@]}"; do
    add_final "$f" "$f"
done
for f in "${fork_picked[@]}"; do
    add_final "mpv-fork/$f" "$fork_dir/$f"
done

if ((${#final[@]} == 0)); then
    echo "nothing selected" >&2
    exit 1
fi

total=0
for entry in "${final[@]}"; do
    total=$((total + $(wc -c <"${entry#*|}")))
done

{
    echo "selected: ${#final[@]} file(s), ${total} bytes"
    echo "branch  : $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "tree    : DIRTY - the bundle contains working-tree contents, not HEAD"
    else
        echo "tree    : clean"
    fi
    if ((fork)); then
        echo "mpv fork: $fork_dir @ $fork_head (${#fork_picked[@]} changed file(s))"
    fi
    ((skipped)) && echo "skipped : $skipped"
} >&2

if ((stat_only)); then
    printf '%s\n' "${final[@]%%|*}" >&2
    exit 0
fi

emit() {
    local display="$1" real="$2"
    local lines size
    lines=$(wc -l <"$real")
    size=$(wc -c <"$real")
    printf '\n'
    printf '=%.0s' {1..78}
    printf '\nFILE: %s  (%s lines, %s bytes)\n' "$display" "$lines" "$size"
    printf '=%.0s' {1..78}
    printf '\n'
    if ((numbers)); then
        nl -ba "$real"
    else
        cat "$real"
    fi
    # A trailing newline per file keeps the last line of one file from running into
    # the banner of the next when this is pasted into a fixed-width viewer.
    printf '\n'
}

header() {
    printf '=%.0s' {1..78}
    printf '\nmpv AI video chain sources  (%s @ %s%s)\n' \
        "$(git rev-parse --abbrev-ref HEAD)" \
        "$(git rev-parse --short HEAD)" \
        "$([[ -n "$(git status --porcelain)" ]] && echo ', working tree')"
    if ((fork)); then
        printf 'plus mpv fork changes at %s\n' "$fork_head"
    fi
    printf '%s file(s), %s bytes, generated %s\n' \
        "${#final[@]}" "$total" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Each block is one file, introduced by a FILE: line. Files under mpv-fork/\n'
    printf 'are working-tree changes in the mpv tree, not the project repo.\n'
    printf '=%.0s' {1..78}
    printf '\n'
}

if [[ -n "$out" ]]; then
    {
        header
        for entry in "${final[@]}"; do emit "${entry%%|*}" "${entry#*|}"; done
    } >"$out"
    echo "wrote $out" >&2
    exit 0
fi

if ((to_clipboard)); then
    {
        header
        for entry in "${final[@]}"; do emit "${entry%%|*}" "${entry#*|}"; done
    } | if command -v wl-copy >/dev/null 2>&1 && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        wl-copy
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard
    else
        echo "no wl-copy or xclip found; writing sources-bundle.txt instead" >&2
        cat >sources-bundle.txt
    fi
else
    {
        header
        for entry in "${final[@]}"; do emit "${entry%%|*}" "${entry#*|}"; done
    } | cat
fi
