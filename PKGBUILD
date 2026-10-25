# Maintainer: HyperRamzey <hyperramzey@users.noreply.github.com>
#
# mpv-dovi-git + NVIDIA Video Effects filters.
#
#   Dolby Vision Profile 7 FEL  : static libplacebo (PL_API_VER >= 370, libdovi)
#   VSR   (AI upscale)          : vf_vsr    via NVIDIA NGX VideoSuperRes
#   TrueHDR (SDR -> HDR10)      : vf_truehdr via NVIDIA NGX TrueHDR
#   VFG   (frame generation)    : vf_vfg    via NVIDIA VideoFrameGeneration
#   DLSS5 NR (noise reduction)  : vf_dlssnr via NGX feature 18, through
#                                 the dlssnr helper (shared memory)
#
# libplacebo and FFmpeg are built STATIC and linked into mpv/libmpv on purpose:
#   * FEL needs libplacebo PL_API_VER >= 367 (pl_frame.enhancement_layer).
#     Arch ships PL_API_VER 360, so the system library cannot be used.
#   * Arch's libavfilter.so NEEDs libplacebo.so.360.  Installing a second,
#     newer libplacebo next to it would put two incompatible copies into one
#     process (libplacebo has no symbol versioning), so both libraries are
#     linked statically instead.  Nothing in the system is replaced.
#
# mpv is pinned to the exact commit the VFX patch was written against.  The
# patch is surgical (19 files: 5 modified + 14 new), not a whole-file overlay,
# so the DoVi path and the upstream ra_pl x2bgr10 mapping stay untouched.
#
# Runtime: the NVIDIA VFX SDK libraries are dlopen()ed, never linked.  They are
# looked up in $HOME/.local/lib/vsr-player; a missing SDK only disables the
# four filters, mpv itself still works.  libcuda.so.1 comes from the driver,
# libnvrtc.so.13 from the 'cuda' package (auto-detected into depends below).

pkgname=mpv-dovi-vfx-git
pkgver=0.41.0_1275_g488fec0789
pkgrel=7
pkgdesc='mpv with Dolby Vision P7 FEL, NVIDIA VSR / TrueHDR / VFG filters (static libplacebo + FFmpeg)'
arch=('x86_64')
url='https://github.com/HyperRamzey/mpv-nvidia-ai-chain'
license=('GPL-2.0-or-later')
depends=('hicolor-icon-theme')
makedepends=(
  'git'
  'meson'
  'ninja'
  'vulkan-headers'
  'wayland-protocols'
  'python-jinja'
  'python-markupsafe'
  'libdovi'
  'shaderc'
  'lcms2'
  'libunwind'
  'luajit'
  'libass'
  'libva'
  'libdrm'
  'libxinerama'
  'libxss'
  'dav1d'
  'libvpx'
  'openssl'
  'libxml2'
  'zlib'
  'bzip2'
  'xz'
  'freetype2'
  'harfbuzz'
  'fribidi'
  'fontconfig'
  'libarchive'
  'libbluray'
  'libdvdnav'
  'libdvdread'
  'libcdio-paranoia'
  'vapoursynth'
  'rubberband'
  'sdl2'
  'zimg'
  'libpulse'
  'pipewire'
  # CUDA toolkit: cuda.h + nvrtc.h for the VFX filters (NVRTC JITs the
  # yuv->rgba kernels at runtime; libnvrtc.so.13 is a real DT_NEEDED).
  'cuda'
)
provides=('mpv' 'mpv-dovi-git' 'libmpv.so=2-64')
conflicts=('mpv' 'mpv-git' 'mpv-dovi-git')
replaces=('mpv-dovi-git')
options=('!emptydirs')
install=mpv.install

_ffmpegver=9.0.2
_nasmver=2.16.03
_mpvcommit=488fec0789e5026804ac8dd03fb749570416d48a
_lpcommit=13d0b79827ea1671f991ca57700e5356af9731a5

source=(
  "git+https://github.com/mpv-player/mpv#commit=${_mpvcommit}"
  "git+https://code.videolan.org/videolan/libplacebo#commit=${_lpcommit}"
  "https://ffmpeg.org/releases/ffmpeg-${_ffmpegver}.tar.xz"
  "https://www.nasm.us/pub/nasm/releasebuilds/${_nasmver}/nasm-${_nasmver}.tar.xz"
  'git+https://github.com/FFmpeg/nv-codec-headers.git'
  'git+https://github.com/Dav1dde/glad.git'
  'git+https://github.com/fastfloat/fast_float.git'
  'find-deps.py'
  'vfx-filters.patch'
)
sha256sums=(
  'SKIP'
  'SKIP'
  '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
  '1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148'
  'SKIP'
  'SKIP'
  'SKIP'
  '7dbf0282eb1f5a46b8d4935daba5566d18b7ec7ad9d487430a78f992c99a8e63'
  '8e487d9f85692d3837900526e055721d99aa69e7078c07b46996845008a3b7a2'
)

pkgver() {
  cd "$srcdir/mpv"
  # No --dirty: the VFX patch modifies tracked files, and a '-' in pkgver is
  # illegal.  The pin makes the version deterministic anyway.
  git describe --always --tags --match 'v[0-9]*' | sed -e 's/^v//' -e 's/-/_/g'
}

prepare() {
  cd "$srcdir/mpv"
  # Fails loudly if the tree drifts from the commit the patch was built for.
  patch -Np1 -i "$srcdir/vfx-filters.patch"
  msg "VFX filters patched into mpv $(git rev-parse --short HEAD)"

  cd "$srcdir/libplacebo"

  # libplacebo's build imports these two submodules from 3rdparty/.
  # Point them at the already-downloaded makepkg sources instead of the network.
  git config submodule.3rdparty/glad.url "$srcdir/glad"
  git config submodule.3rdparty/fast_float.url "$srcdir/fast_float"
  git -c protocol.file.allow=always submodule update --init \
    3rdparty/glad 3rdparty/fast_float
}

build() {
  local prefix="$srcdir/prefix"
  local tools="$srcdir/tools"
  local jobs

  jobs=$(nproc)

  # Arch's libpulse.pc advertises its private implementation library in
  # Libs.private.  meson passes pkg-config --static (-Dprefer_static=true), so
  # that entry would put libpulsecommon-17.0.so into mpv's DT_NEEDED even
  # though it lives in /usr/lib/pulseaudio, outside the loader path.  libpulse
  # already resolves it through its own RUNPATH; hide the private entry from
  # static dependency resolution instead of adding a private rpath.
  local pulse_pc
  pulse_pc="$(pkg-config --variable=pcfiledir libpulse)/libpulse.pc"
  [[ -f "$pulse_pc" ]] || { error "libpulse.pc not found"; return 1; }
  mkdir -p "$srcdir/pcshadow"
  sed '/^Libs\.private:/d' "$pulse_pc" > "$srcdir/pcshadow/libpulse.pc"

  # harfbuzz's static closure drags in libglib-2.0.a, while every other glib
  # consumer on the system (harfbuzz.so, libass.so, libpulse.so) links the
  # shared libglib-2.0.  Adding a second, static copy to mpv makes binutils
  # 2.45+ reject the final link:
  #   hidden symbol `g_get_current_time' in /usr/lib/libglib-2.0.a(gmain.c.o)
  #   is referenced by DSO
  # Keep harfbuzz's compile flags -- its Cflags inherit glib's include paths --
  # and drop glib from its static link closure; harfbuzz.so already carries
  # libglib-2.0.so.0 in DT_NEEDED.
  local hb_pc glib_cflags
  hb_pc="$(pkg-config --variable=pcfiledir harfbuzz)/harfbuzz.pc"
  [[ -f "$hb_pc" ]] || { error "harfbuzz.pc not found"; return 1; }
  glib_cflags="$(pkg-config --cflags glib-2.0)"
  awk -v extra="$glib_cflags" '
    /^Requires\.private:/ {
      gsub(/glib-2\.0[^,]*,?[[:space:]]*/, "")
      sub(/,[[:space:]]*$/, "")
      print; next
    }
    /^Cflags:/ { print $0 " " extra; next }
    { print }
  ' "$hb_pc" > "$srcdir/pcshadow/harfbuzz.pc"

  export PKG_CONFIG_PATH="$srcdir/pcshadow:$prefix/lib/pkgconfig"
  export PATH="$tools/bin:$PATH"

  # nasm is required for FFmpeg's x86 SIMD; not installed on the target box.
  cd "$srcdir/nasm-${_nasmver}"
  ./configure --prefix="$tools"
  make -j"$jobs"
  make install

  # NVDEC/CUVID headers (headers only, no CUDA toolkit needed at build time).
  cd "$srcdir/nv-codec-headers"
  make install PREFIX="$prefix"

  msg 'Building libplacebo (static, FEL-capable)'
  cd "$srcdir/libplacebo"
  meson setup build-lp \
    --prefix="$prefix" \
    --libdir=lib \
    --buildtype=plain \
    --default-library=static \
    -Dvulkan=enabled \
    -Dshaderc=enabled \
    -Ddovi=enabled \
    -Dlibdovi=enabled \
    -Dlcms=enabled \
    -Dopengl=enabled \
    -Dglslang=disabled \
    -Ddemos=false \
    -Dtests=false \
    -Dbench=false \
    -Dfuzz=false \
    -Dunwind=disabled
  meson compile -C build-lp
  meson install -C build-lp

  # libplacebo's static archive contains C++ (src/convert.cc), but upstream's
  # generated .pc omits -lstdc++ from Libs.private.  Without this, every
  # `pkg-config --static` link test fails with
  #   undefined reference to std::to_chars(char*, char*, double)
  # and FFmpeg's configure reports "libplacebo >= 7.351.0 not found".
  printf 'Libs.private: -lstdc++\n' >> "$prefix/lib/pkgconfig/libplacebo.pc"

  # These two asserts are the whole point of the package.  Fail loudly if a
  # future libplacebo drops the FEL API instead of silently shipping a player
  # without it.
  local pl_api
  pl_api=$(sed -n 's/^#define PL_API_VER \([0-9]*\)$/\1/p' "$prefix/include/libplacebo/config.h")
  [[ -n "$pl_api" && "$pl_api" -ge 370 ]] \
    || { error "libplacebo PL_API_VER=$pl_api, need >= 370 for DoVi P7 FEL"; return 1; }
  grep -q '^#define PL_HAVE_LIBDOVI 1$' "$prefix/include/libplacebo/config.h" \
    || { error "libplacebo built without libdovi"; return 1; }
  msg "libplacebo PL_API_VER=$pl_api (FEL: yes)"

  msg 'Building FFmpeg (static, 9.0.2)'
  cd "$srcdir/ffmpeg-${_ffmpegver}"
  # -fno-lto is required: libswscale/x86/rgb2rgb.c defines constants that are
  # only referenced from inline asm constraints.  With makepkg's -flto=auto the
  # LTO partitioner drops them and the final mpv link fails on mul15_hi/mask24*.
  ./configure \
    --prefix="$prefix" \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --disable-doc \
    --disable-debug \
    --disable-programs \
    --pkg-config-flags=--static \
    --extra-cflags="-fno-lto -I$prefix/include" \
    --extra-ldflags="-L$prefix/lib" \
    --enable-libdav1d \
    --enable-libvpx \
    --enable-libplacebo \
    --enable-vulkan \
    --enable-ffnvcodec \
    --enable-nvdec \
    --enable-cuvid \
    --enable-openssl \
    --enable-libxml2
  make -j"$jobs"
  make install

  msg 'Building mpv (static libplacebo + FFmpeg, VFX filters)'
  cd "$srcdir/mpv"
  meson setup build \
    --prefix=/usr \
    --sysconfdir=/etc \
    --buildtype=plain \
    --wrap-mode=nodownload \
    -Dlibmpv=true \
    -Dprefer_static=true \
    -Dvulkan=enabled \
    -Dwayland=enabled \
    -Dvaapi=auto \
    -Ddvbin=enabled \
    -Dlua=luajit \
    -Djavascript=disabled \
    -Dmanpage-build=disabled \
    -Dhtml-build=disabled \
    -Dpdf-build=disabled \
    -Dc_link_args='-Wl,--exclude-libs,ALL' \
    -Dcpp_link_args='-Wl,--exclude-libs,ALL'
  meson compile -C build
}

check() {
  cd "$srcdir/mpv"

  # Both binaries must be self-contained: no libav*, no libplacebo from the
  # system, and no unresolved NEEDED entries.
  local libmpv
  libmpv=$(find build -maxdepth 1 -type f -name 'libmpv.so.2.*' -print -quit)
  [[ -n "$libmpv" ]] || { error "libmpv shared library was not built"; return 1; }

  local bin
  for bin in build/mpv "$libmpv"; do
    ldd "$bin" > "$srcdir/ldd-$(basename "$bin").txt"
    if grep -Eq 'libav(codec|filter|format|util)|libplacebo|not found' \
        "$srcdir/ldd-$(basename "$bin").txt"; then
      error "$bin links a shared ffmpeg/libplacebo or has unresolved libraries:"
      grep -E 'libav(codec|filter|format|util)|libplacebo|not found' \
        "$srcdir/ldd-$(basename "$bin").txt" >&2
      return 1
    fi
  done

  # libpulsecommon is PulseAudio's private implementation library.  It must
  # not appear in DT_NEEDED: it lives outside the loader path and its soname
  # changes with PulseAudio releases.
  if readelf -d build/mpv | grep -q 'libpulsecommon'; then
    error "mpv directly links PulseAudio's private libpulsecommon"
    return 1
  fi

  # Static libplacebo/FFmpeg symbols must not be exported from libmpv, while
  # the public mpv_* client API must remain visible.
  if nm -D --defined-only "$libmpv" \
      | grep -Eq ' (pl_|avcodec_|avdevice_|avfilter_|avformat_|avutil_|sws_|swresample_)'; then
    error "libmpv exports symbols from statically linked libraries"
    return 1
  fi
  nm -D --defined-only "$libmpv" | grep -q ' T mpv_client_api_version' \
    || { error "libmpv does not export the mpv client API"; return 1; }

  build/mpv --version | grep -q 'libplacebo v' || return 1
  build/mpv --version
  build/mpv --vo=help | grep -q 'gpu-next' || return 1
  build/mpv --vf=format=help 2>&1 | grep -q 'enhancement-layer' || return 1

  # The five VFX filters must be registered, not just compiled.
  build/mpv --vf=vsr=help 2>&1 | grep -q 'Scale' \
    || { error "vf_vsr is not registered in the binary"; return 1; }
  build/mpv --vf=hwup=help 2>&1 | grep -q . \
    || { error "vf_hwup is not registered in the binary"; return 1; }
  build/mpv --vf=truehdr=help 2>&1 | grep -q 'luminance' \
    || { error "vf_truehdr is not registered in the binary"; return 1; }
  build/mpv --vf=vfg=help 2>&1 | grep -q 'fps' \
    || { error "vf_vfg is not registered in the binary"; return 1; }
  # dlssnr has no single distinctive option name, so check two: the profile
  # enum from NeuralScreen and the override string that carries per-pass
  # settings.
  build/mpv --vf=dlssnr=help 2>&1 | grep -q 'cinematic' \
    || { error "vf_dlssnr is not registered in the binary"; return 1; }
  build/mpv --vf=dlssnr=help 2>&1 | grep -q 'override2' \
    || { error "vf_dlssnr is missing its per-pass overrides"; return 1; }
  msg 'VFX filters registered: hwup, vsr, truehdr, vfg, dlssnr'
}

package() {
  cd "$srcdir/mpv"
  meson install -C build --no-rebuild --destdir "$pkgdir"

  install -Dm644 LICENSE.GPL "$pkgdir/usr/share/licenses/$pkgname/LICENSE.GPL"
  install -Dm644 LICENSE.LGPL "$pkgdir/usr/share/licenses/$pkgname/LICENSE.LGPL"
  install -Dm644 Copyright "$pkgdir/usr/share/licenses/$pkgname/Copyright"

  # Drop the unversioned .so symlink; nothing in the package links against it.
  rm -f "$pkgdir/usr/lib/libmpv.so"

  local detected
  detected=$(python3 "$srcdir/find-deps.py" \
    "$pkgdir/usr/bin/mpv" "$pkgdir"/usr/lib/libmpv.so.2)
  depends=($detected 'hicolor-icon-theme')
  msg "Auto-detected runtime dependencies: ${depends[*]}"
}
