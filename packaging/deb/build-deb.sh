#!/usr/bin/env bash
# =============================================================================
# build-deb.sh — build the Debian/Ubuntu package for mpv-dovi-vfx.
#
# Ubuntu has neither the pinned libplacebo (PL_API_VER 399, DoVi FEL) nor a
# libdovi package, so this reuses the PKGBUILD's prepare()/build()/check() on
# Ubuntu 24.04 and stages the result as a .deb:
#
#   * libdovi 3.4.0 is built from source with cargo-c (noble has no libdovi).
#   * wayland 1.23.1 is built for the compile step only: the pinned mpv
#     requires wayland-client/scanner >= 1.23 and noble ships 1.22, but the
#     APIs mpv calls exist in 1.22, so the package links the distro library.
#   * libplacebo and FFmpeg are static and linked into mpv, exactly like the
#     Arch package; check() asserts no dynamic libav*/libplacebo escapes.
#   * The NVIDIA driver stub (libcuda.so) is placed on the link path. The
#     binary records NEEDED libcuda.so.1, which only the driver provides at
#     runtime; no CUDA execution happens during the build.
#   * /etc/mpv gets ai.conf, input.conf, the Lua scripts and the beam shader,
#     and /usr/bin/mpv-ai wraps the profile, so `mpv-ai <file>` works with no
#     per-user setup.
#
# Requirements (Ubuntu 24.04, see .github/workflows/release.yml for the full
# list): build-essential meson ninja-build pkg-config git curl, python3-jinja2,
# python3-markupsafe, rustup, cargo-c built with it (noble's 0.9.19 embeds a
# cargo that cannot parse libdovi's edition-2024 manifest), nvidia-cuda-toolkit
# and the -dev packages of every library mpv is configured against.
#
# Usage: packaging/deb/build-deb.sh
#   OUTDIR=/path   where the .deb is written          (default: <repo>/dist-deb)
#   WORKDIR=/path  scratch tree                       (default: <repo>/build/deb)
#   JOBS=n         parallel make jobs                 (default: nproc)
#   KEEP=1         keep the scratch tree (no initial clean)
# =============================================================================
set -euo pipefail
# pkgver, pkgrel, _ffmpegver, source and sha256sums come from the PKGBUILD,
# which is sourced at run time; shellcheck cannot see through that, hence the
# targeted SC2154 disables below.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=${WORKDIR:-$root/build/deb}
out=${OUTDIR:-$root/dist-deb}

pkgname=mpv-dovi-vfx
srcdir=$work/src
pkgroot=$work/pkgroot
# PKGBUILD build() installs its own prefix at $srcdir/prefix; libdovi has to
# land in the same tree so libplacebo's dependency('dovi') resolves from
# $prefix/lib/pkgconfig.
prefix=$srcdir/prefix
cuda_home=$work/cuda

msg() { printf '==> %s\n' "$*"; }
warning() { printf 'WARNING: %s\n' "$*" >&2; }
error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
for tool in git curl tar gzip meson ninja pkg-config python3 cc c++ make \
            readelf ldd dpkg-deb dpkg cargo rustc cargo-cinstall patch; do
    command -v "$tool" >/dev/null 2>&1 || error "missing build tool: $tool"
done

rust_version=$(rustc --version | awk '{print $2}')
oldest=$(printf '%s\n1.88.0\n' "$rust_version" | sort -V | head -1)
[ "$oldest" = 1.88.0 ] \
    || error "rustc $rust_version is older than the libdovi 3.4.0 minimum (1.88.0)"

if [ "${KEEP:-0}" = 1 ]; then
    msg "Keeping scratch tree $work"
else
    rm -rf "$work"
fi
rm -rf "$pkgroot"
mkdir -p "$srcdir" "$pkgroot" "$out" "$prefix" "$cuda_home/include" "$cuda_home/lib64"

# ---------------------------------------------------------------------------
# CUDA: headers, NVRTC and the driver stub
# ---------------------------------------------------------------------------
cuda_stub=
for cand in \
    /usr/lib/x86_64-linux-gnu/stubs/libcuda.so \
    /usr/local/cuda/lib64/stubs/libcuda.so \
    /usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so; do
    if [ -e "$cand" ]; then cuda_stub=$cand; break; fi
done
[ -n "$cuda_stub" ] \
    || error "libcuda.so driver stub not found; install nvidia-cuda-toolkit"
ln -sfn "$cuda_stub" "$cuda_home/lib64/libcuda.so"
ln -sfn "$cuda_stub" "$cuda_home/lib64/libcuda.so.1"

nvrtc_so=
for cand in \
    /usr/lib/x86_64-linux-gnu/libnvrtc.so \
    /usr/local/cuda/lib64/libnvrtc.so \
    /usr/local/cuda/targets/x86_64-linux/lib/libnvrtc.so; do
    if [ -e "$cand" ]; then nvrtc_so=$cand; break; fi
done
[ -n "$nvrtc_so" ] || error "libnvrtc.so not found; install nvidia-cuda-toolkit"
ln -sfn "$nvrtc_so" "$cuda_home/lib64/libnvrtc.so"

for header in cuda.h nvrtc.h; do
    src_header=
    for cand in /usr/include /usr/local/cuda/include; do
        if [ -e "$cand/$header" ]; then src_header=$cand/$header; break; fi
    done
    [ -n "$src_header" ] || error "$header not found; install nvidia-cuda-toolkit"
    ln -sfn "$src_header" "$cuda_home/include/$header"
done

export CUDA_HOME="$cuda_home" CUDA_PATH="$cuda_home"
export LIBRARY_PATH="$cuda_home/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$prefix/lib:$cuda_home/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CFLAGS="${CFLAGS:--O2 -pipe}"
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"
export LDFLAGS="-Wl,-O1,--as-needed,-z,relro,-z,now -L$cuda_home/lib64${LDFLAGS:+ $LDFLAGS}"
msg "CUDA headers: $cuda_home/include (stub: $cuda_stub)"

# ---------------------------------------------------------------------------
# Pinned sources, straight from the PKGBUILD
# ---------------------------------------------------------------------------
source "$root/PKGBUILD"
# PKGBUILD sets pkgname=mpv-dovi-vfx-git; the Debian package uses its own name
# (and its own conflict/replace semantics). pkgver/pkgrel stay as pinned.
pkgname=mpv-dovi-vfx

fetch_git() {
    local url=$1 sha=$2 dir=$3 full=${4:-0}
    if [ ! -d "$dir/.git" ]; then
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "$url"
    fi
    if ! git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        if [ "$full" = 1 ]; then
            # Submodule sources (glad, fast_float, Vulkan-Headers) are cloned
            # by libplacebo at the gitlinks *it* records, which are not the
            # commits pinned in source=(). A depth-1 fetch of the pin does not
            # contain them; these repos are small, so fetch all branches and
            # the pin itself in case it only exists as a detached commit.
            git -C "$dir" fetch -q origin
            git -C "$dir" fetch -q origin "$sha" 2>/dev/null || true
        else
            # GitHub accepts a direct SHA fetch; the fallback covers servers
            # that only advertise refs (the commit is reachable from a branch).
            git -C "$dir" fetch -q --depth=1 origin "$sha" 2>/dev/null \
                || git -C "$dir" fetch -q --filter=blob:none origin \
                     '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' \
                || git -C "$dir" fetch -q origin
        fi
    fi
    git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null \
        || error "commit $sha is not reachable in $url"
    git -C "$dir" checkout -q --detach "$sha"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] \
        || error "checkout of $sha failed in $dir"
}

msg 'Fetching pinned sources'
# shellcheck disable=SC2154
for i in "${!source[@]}"; do
    src=${source[$i]}
    sum=${sha256sums[$i]}
    case "$src" in
        git+*)
            url=${src#git+}
            commit=${url#*#commit=}
            url=${url%%#commit=*}
            name=$(basename "$url" .git)
            dir=$srcdir/$name
            msg "  git $url @ ${commit:0:12}"
            case "$name" in
                glad|fast_float|Vulkan-Headers) full=1 ;;
                *) full=0 ;;
            esac
            fetch_git "$url" "$commit" "$dir" "$full"
            ;;
        http*://*)
            file=$srcdir/$(basename "$src")
            [ -f "$file" ] || curl -fL --retry 3 --retry-delay 2 -o "$file" "$src"
            [ "$sum" = SKIP ] || echo "$sum  $file" | sha256sum -c -
            case "$file" in
                *.tar.xz|*.tar.gz|*.tgz) tar -xf "$file" -C "$srcdir" ;;
            esac
            ;;
        *)
            file=$srcdir/$src
            cp -f "$root/$src" "$file"
            [ "$sum" = SKIP ] || echo "$sum  $file" | sha256sum -c -
            ;;
    esac
done

# ---------------------------------------------------------------------------
# libdovi 3.4.0 (no libdovi package in noble)
# ---------------------------------------------------------------------------
dovi_tag=libdovi-3.4.0
dovi_dir=$srcdir/dovi_tool-$dovi_tag
if [ ! -f "$prefix/lib/pkgconfig/dovi.pc" ]; then
    if [ ! -d "$dovi_dir" ]; then
        msg "Fetching $dovi_tag"
        curl -fL --retry 3 --retry-delay 2 -o "$work/$dovi_tag.tar.gz" \
            "https://github.com/quietvoid/dovi_tool/archive/refs/tags/$dovi_tag.tar.gz"
        tar -xf "$work/$dovi_tag.tar.gz" -C "$srcdir"
    fi
    msg 'Building libdovi 3.4.0 (cargo-c)'
    (
        cd "$dovi_dir/dolby_vision"
        # cargo-c enables the 'capi' feature automatically when the crate
        # declares one; pass it explicitly so the intent is visible.
        cargo cinstall --release --features capi \
            --prefix "$prefix" --libdir lib
    )
fi
[ -f "$prefix/lib/pkgconfig/dovi.pc" ] || error 'libdovi was not installed'
grep -q '^Version: 3\.4' "$prefix/lib/pkgconfig/dovi.pc" 2>/dev/null \
    || warning "dovi.pc does not report 3.4 (see $prefix/lib/pkgconfig/dovi.pc)"

# ---------------------------------------------------------------------------
# wayland 1.23.1 (noble ships 1.22; pinned mpv requires client/scanner >= 1.23)
# ---------------------------------------------------------------------------
# Only the build needs 1.23: mpv's meson gates wayland-client, wayland-cursor
# and wayland-scanner on 1.23, while the API it actually uses exists in the
# system 1.22 runtime, so the .deb links libwayland-client.so.0 and lets the
# distro provide it.
wayland_ver=1.23.1
wayland_sha=864fb2a8399e2d0ec39d56e9d9b753c093775beadc6022ce81f441929a81e5ed
wayland_dir=$srcdir/wayland-$wayland_ver
if [ ! -f "$prefix/lib/pkgconfig/wayland-client.pc" ]; then
    if [ ! -d "$wayland_dir" ]; then
        msg "Fetching wayland $wayland_ver"
        curl -fL --retry 3 --retry-delay 2 \
            -o "$work/wayland-$wayland_ver.tar.xz" \
            "https://gitlab.freedesktop.org/wayland/wayland/-/releases/$wayland_ver/downloads/wayland-$wayland_ver.tar.xz"
        echo "$wayland_sha  $work/wayland-$wayland_ver.tar.xz" | sha256sum -c -
        tar -xf "$work/wayland-$wayland_ver.tar.xz" -C "$srcdir"
    fi
    msg "Building wayland $wayland_ver"
    meson setup "$wayland_dir/build" "$wayland_dir" \
        --prefix="$prefix" --libdir=lib --buildtype=plain \
        -Ddocumentation=false -Dtests=false -Ddtd_validation=false
    meson compile -C "$wayland_dir/build"
    meson install -C "$wayland_dir/build"
fi
[ -x "$prefix/bin/wayland-scanner" ] || error 'wayland-scanner was not installed'
# Must precede /usr/bin so mpv's find_program(version: '>=1.23.0') sees it.
export PATH="$prefix/bin:$PATH"

# ---------------------------------------------------------------------------
# Reuse the PKGBUILD build
# ---------------------------------------------------------------------------
export srcdir
export pkgdir=$pkgroot
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

msg 'prepare()'
prepare
msg 'build()'
build
msg 'check()'
check

# ---------------------------------------------------------------------------
# Stage the package tree
# ---------------------------------------------------------------------------
msg 'Staging /usr from the meson build'
# --strip matches what makepkg does for the Arch package; the .deb should not
# carry full symbol tables.
meson install -C "$srcdir/mpv/build" --no-rebuild --strip --destdir "$pkgroot"

[ -x "$pkgroot/usr/bin/mpv" ] || error 'staging did not produce /usr/bin/mpv'

libdir_rel=$(cd "$pkgroot/usr" && find . -type f -name 'libmpv.so.2.*' -printf '%h\n' -quit)
[ -n "$libdir_rel" ] || error 'staging did not produce libmpv.so.2'
libdir=$pkgroot/usr/${libdir_rel#./}
msg "libmpv installed in /usr/${libdir_rel#./}"

docdir=$pkgroot/usr/share/doc/$pkgname
licdir=$pkgroot/usr/share/licenses/$pkgname
install -d "$docdir" "$licdir"
install -m644 "$srcdir/mpv/LICENSE.GPL" "$srcdir/mpv/LICENSE.LGPL" \
    "$srcdir/mpv/Copyright" "$licdir/"
install -m644 "$root/README.md" "$root/docs/CRT-BEAM.md" "$root/LICENSE.md" "$docdir/"

# libdovi: bundle the runtime (noble has no package for it). The SONAME is
# libdovi.so.3; ship the versioned file and its link, never the dev symlink.
dovi_real=$(readlink -f "$prefix/lib/libdovi.so.3")
[ -f "$dovi_real" ] || error "libdovi.so.3 is missing from $prefix/lib"
install -Dm755 -s "$dovi_real" "$libdir/$(basename "$dovi_real")"
ln -sfn "$(basename "$dovi_real")" "$libdir/libdovi.so.3"

msg 'Installing system-wide mpv configuration'
install -d "$pkgroot/etc/mpv/scripts" "$pkgroot/etc/mpv/shaders" "$pkgroot/usr/bin"
install -m644 "$root/ai.conf" "$pkgroot/etc/mpv/ai.conf"
install -m644 "$root/input.conf" "$pkgroot/etc/mpv/input.conf"
install -m644 "$root/scripts/vfg-sync.lua" \
    "$pkgroot/etc/mpv/scripts/vfg-sync.lua"
install -m644 "$root/scripts/nr-toggle.lua" \
    "$pkgroot/etc/mpv/scripts/nr-toggle.lua"
install -m644 "$root/scripts/beam-sim.lua" \
    "$pkgroot/etc/mpv/scripts/beam-sim.lua"
install -m644 "$root/shaders/crt-beam-sim.glsl" \
    "$pkgroot/etc/mpv/shaders/crt-beam-sim.glsl"
install -m755 "$root/packaging/mpv-ai" "$pkgroot/usr/bin/mpv-ai"

# ---------------------------------------------------------------------------
# Runtime dependencies: what the staged binaries actually need
# ---------------------------------------------------------------------------
msg 'Resolving runtime dependencies from DT_NEEDED'
declare -A depmap=()
map_dep() {
    local so=$1 path pkg
    case "$so" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|ld-linux*)
            return 0 ;;
        libcuda.so.1)
            # NVIDIA driver, deliberately not a hard dependency: the package
            # name changes with every driver branch. See Recommends.
            return 0 ;;
        libdovi.so.3)
            # Bundled above (noble has no libdovi package).
            return 0 ;;
    esac
    path=$(ldconfig -p | awk -v s="$so" '$1 == s {print $NF; exit}')
    if [ -z "$path" ]; then
        warning "no provider for $so"
        return 0
    fi
    pkg=$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$pkg" ]; then
        warning "no package owns $path ($so)"
        return 0
    fi
    depmap[$pkg]=1
}

mapfile -t staged_bins < <(find "$pkgroot/usr" -type f \
    \( -name mpv -o -name 'libmpv.so.2.*' \) -print)
[ "${#staged_bins[@]}" -gt 0 ] || error 'no staged binaries to scan'
for bin in "${staged_bins[@]}"; do
    while IFS= read -r so; do
        map_dep "$so"
    done < <(readelf -d "$bin" \
        | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u)
done

runtime_deps=(libc6 hicolor-icon-theme)
for p in "${!depmap[@]}"; do
    runtime_deps+=("$p")
done
old_ifs=$IFS
IFS=,
depends_line="${runtime_deps[*]}"
IFS=$old_ifs
msg "Depends: $depends_line"

# Both binaries must load with only the staged tree plus the CUDA stub. A
# missing symbol here is a broken package, not a warning.
msg 'Checking staged binaries are runnable'
if LD_LIBRARY_PATH="$pkgroot/usr/${libdir_rel#./}:$prefix/lib:$cuda_home/lib64" \
        ldd "$pkgroot/usr/bin/mpv" | grep -q 'not found'; then
    LD_LIBRARY_PATH="$pkgroot/usr/${libdir_rel#./}:$prefix/lib:$cuda_home/lib64" \
        ldd "$pkgroot/usr/bin/mpv" | grep 'not found' >&2
    error 'staged mpv has unresolved shared libraries'
fi
staged_version=$(LD_LIBRARY_PATH="$pkgroot/usr/${libdir_rel#./}:$prefix/lib:$cuda_home/lib64" \
    "$pkgroot/usr/bin/mpv" --version | head -1)
case "$staged_version" in
    *'mpv '*) ;;
    *) error "staged mpv does not run: $staged_version" ;;
esac
msg "$staged_version"

# ---------------------------------------------------------------------------
# Control metadata
# ---------------------------------------------------------------------------
# pkgver/pkgrel come from the PKGBUILD
# shellcheck disable=SC2154
debver=${pkgver//_/.}-${pkgrel}
control=$pkgroot/DEBIAN
install -d "$control"

installed_size=$(du -sk "$pkgroot" | cut -f1)
# _ffmpegver comes from the PKGBUILD
# shellcheck disable=SC2154
cat > "$control/control" <<EOF
Package: $pkgname
Version: $debver
Section: video
Priority: optional
Architecture: amd64
Maintainer: HyperRamzey <hyperramzey@users.noreply.github.com>
Homepage: https://github.com/HyperRamzey/mpv-nvidia-ai-chain
Installed-Size: $installed_size
Depends: $depends_line
Recommends: libnvidia-compute-550 | libnvidia-compute-535 | libnvidia-compute-470 | libnvidia-compute-550-server | libnvidia-compute-535-server | libnvidia-compute-470-server
Provides: mpv, libmpv2
Conflicts: mpv, libmpv2
Replaces: mpv, libmpv2
Description: mpv with Dolby Vision P7 FEL and NVIDIA VFX filters
 mpv built from a pinned upstream commit with static libplacebo
 (PL_API_VER 399, libdovi) and static FFmpeg ${_ffmpegver}, plus NVIDIA
 VSR, TrueHDR, VFG and DLSS neural-rendering video filters.
 .
 Dolby Vision profile 7 FEL is decoded with the enhancement layer and
 tone-mapped at 12 bits. SDR sources can be upscaled with
 VideoSuperRes, converted to HDR10 with TrueHDR and frame-generated
 with VFG. The CRT beam simulator added by this chain is shipped as a
 libplacebo user shader and driven by a Lua controller.
 .
 This package installs the player, a system-wide configuration in
 /etc/mpv (ai.conf, input.conf, scripts, shaders) and the mpv-ai
 wrapper in /usr/bin. It conflicts with the distribution mpv package,
 which it replaces, and bundles the libdovi runtime it was built with.
 .
 The NVIDIA VFX SDK libraries are loaded at runtime from
 \$HOME/.local/lib/vsr-player and are not part of this package.
EOF

cat > "$control/conffiles" <<'EOF'
/etc/mpv/ai.conf
/etc/mpv/input.conf
EOF

cat > "$docdir/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: mpv
Source: https://github.com/mpv-player/mpv

Files: *
Copyright: mpv contributors
License: GPL-2.0-or-later
 On Debian systems the complete text of the GPL version 2 is in
 /usr/share/common-licenses/GPL-2.

Files: usr/lib/x86_64-linux-gnu/libdovi.so.*
Copyright: quietvoid
License: MIT
 Bundled because Ubuntu 24.04 has no libdovi package.
EOF

{
    printf '%s (%s) unstable; urgency=medium\n\n' "$pkgname" "$debver"
    printf '  * Automated build from commit %s.\n\n' "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf ' -- HyperRamzey <hyperramzey@users.noreply.github.com>  %s\n' "$(date -R)"
} | gzip -9n > "$docdir/changelog.Debian.gz"

( cd "$pkgroot" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
    | sort -z | xargs -0 md5sum > DEBIAN/md5sums )

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
deb=$out/${pkgname}_${debver}_amd64.deb
msg "Building $deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb" >/dev/null
dpkg-deb --info "$deb" | sed 's/^/    /'
dpkg-deb --contents "$deb" | grep -E 'etc/mpv|usr/bin/(mpv|mpv-ai)|libdovi' | sed 's/^/    /'

( cd "$out" && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256" )
msg "Built $deb ($(du -h "$deb" | cut -f1))"
