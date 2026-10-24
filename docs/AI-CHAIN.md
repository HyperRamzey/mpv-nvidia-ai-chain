# NVIDIA VFX AI chain for mpv — built, installed, verified

**Status: DONE and installed (2026-10-24).** `mpv-dovi-vfx-git` replaced
`mpv-dovi-git` on this machine. Dolby Vision P7 FEL path unchanged, NVIDIA VSR /
TrueHDR / **DLSS 5 NR** / VFG compiled into the same binary and driven by an
opt-in config.

The NR design and its measurements are in **`DLSS5-NR-PLAN.md`** (design of
record). This file is the operation manual: what exists, how to run it, and the
traps.

---

## 1. What exists now

| Thing | Path |
| --- | --- |
| Package | `mpv-dovi-vfx-git 0.41.0_1275_g488fec0789-5` (`/usr/bin/mpv`, `/usr/lib/libmpv.so.2.6.0`) |
| Built artefact | `~/ai-video/build/arch/mpv-dovi-vfx-git-0.41.0_1275_g488fec0789-5-x86_64.pkg.tar.zst` |
| PKGBUILD + sources | `~/ai-video/build/arch/` (`PKGBUILD`, `vfx-filters.patch`, `find-deps.py`, `mpv.install`) |
| AI chain config | `~/.config/mpv/ai.conf` (six auto profiles + `[ai]`) |
| NR (VSR denoiser) config | `~/.config/mpv/nr.conf` |
| Wrappers | `~/.local/bin/mpv-ai`, `~/.local/bin/mpv-nr` |
| NR helper | `~/.local/bin/dlssnr-helper` — **must be running** for `dlssnr` |
| Old player backup | `~/ai-video/build/backup-mpv-dovi-git/` (binary + libmpv + headers) |
| Patch (22 files, 8527 lines) | `~/ai-video/build/arch/vfx-filters.patch`, sha256 `9d755ffb…f33788` |

Pins: mpv `488fec0789e5026804ac8dd03fb749570416d48a`, libplacebo
`13d0b79827ea1671f991ca57700e5356af9731a5` (PL_API_VER 377, libdovi), FFmpeg static
9.0.2, nv-codec-headers, nasm 2.16.03.

`/usr/bin/mpv --version` → `v0.41.0-1275-g488fec078-dirty`, `libplacebo v7.377.0`,
`FFmpeg version: 9.0.2`. DoVi FEL option still present (`--vf=format=help` lists
`enhancement-layer`). The patch applies cleanly to a pristine `488fec0789`
(`patch -Np1 --dry-run`, 0 rejects).

## 2. How to use

| Command | Behaviour |
| --- | --- |
| `mpv file.mkv` | unchanged: `hwdec=vulkan,nvdec`, shaders, `[HDR]` profiles. Use for Dolby Vision with FEL and no AI. |
| `mpv-ai file.mkv` | NVDEC + `hwup → [vsr] → truehdr → dlssnr → vfg` (chain picked by height and DV profile, see §3) |
| `mpv-nr file.mkv` | VSR denoiser only, 1:1, no upscale / no HDR pass / no VFG |

Both wrappers accept every normal mpv argument (`mpv-ai --fullscreen --start=10:00 f.mkv`).
Tuning is a config edit; a command-line `--vf=` cannot win, because the profile
replaces it. Live changes without a restart: `vf-command dlssnr passes 1`,
`vf-command vfg fps 4`. The chains carry explicit `@dlssnr:` / `@vfg:` labels for
exactly this reason — without a `@label:`, mpv generates `dlssnr.00` / `vfg.00`
and the unlabelled command fails with `error running command` (trap 13).

The NR helper is not a service and does not survive a reboot:

```
~/.local/bin/dlssnr-helper start | status | stop
# log: ~/.local/state/dlssnr/helper.log
```

Without it, `dlssnr` fails open — it logs and stays inert; playback continues.

## 3. Resolution policy (verified per case)

Chain applied: `hwup, vsr:scale=4/3, truehdr:enable=yes:luminance=630,
dlssnr:passes=2:profile=cinematic:work_scale=0.5:size=panel,
vfg:fps=auto:max-fps=110`.

| Source | Chain | Observed |
| --- | --- | --- |
| 1920×1080 SDR 48 fps | full (`ai-vsr`) | `vsr: init 1920x1080 -> 2560x1440`, `dlssnr-status: passes=2 work=1280x720 cost≈11.6ms`, `vfg k=2 out=96` |
| 1280×720 SDR | full | `vsr: init 1280x720 -> 1707x960` |
| 3840×2160 P7 48 fps | `ai-big` | no VSR; `truehdr-status: mode=passthrough` (PQ); NR at `work=1280x720`; `vfg k=2 out=96` |
| 3840×2160 HDR10 48 fps | `ai-big` | same, `truehdr-status: mode=passthrough` |
| 3840×2160 P5 | `ai-big-p5` | no filters at all: native libplacebo DoVi path (see §6) |
| any 2160p | — | `dlssnr`'s `size=panel` shrinks to the panel with its own Mitchell kernel; the VO's `dscale` has nothing left to do |

`Unsupported format` errors: **0** in every case. VFG output rate measured with
`${estimated-vf-fps}`: **96** on 24 and 48 fps sources, **24** with the chain off.

The gate keys on **source** height (`video-params/h` is pre-filter — it still reports
1080 while the chain outputs 1440), so 720p/1080p take VSR, 1440p/2160p do not.

`fps=auto` picks the largest integer K in 2..4 that fits under `max-fps=110`:
48→2 (96), 24→4 (96), 120→passthrough (`reason=max-fps`). The cap is 110, not the
panel's 165, because 2-pass NR + VFG tops out near 96–100 fps presented
(measurements in `DLSS5-NR-PLAN.md` §6).

## 4. NR (noise reduction) — two different things, do not confuse them

| | `mpv-ai` (`dlssnr`) | `mpv-nr` (`vsr` denoiser) |
| --- | --- | --- |
| What it is | **DLSS 5 NR**, NGX feature 18, 2 passes, cinematic preset | VSR's built-in denoise stage |
| Where in the chain | in-chain filter, **before** VFG | in-chain, 1:1 only |
| Resolution | panel-res anchor + `work_scale` proxy | native 1:1 |
| Output colour space | equal to input by construction | equal to input, range normalised to full |

The requirement "NR is not the VSR denoiser" is why `dlssnr` exists. How it works
(residual composite in display space, `den = white + peak(L)` on PQ, `den = 1` on
SDR, anchor never replaced) is in `DLSS5-NR-PLAN.md` §3 and §6.

`mpv-nr` = `hwdec=nvdec`, `vf=hwup,vsr:scale=-1:denoise=medium`. Levels: `off low
medium high ultra`. Verified 1:1 (`vsr: init 1920x1080 -> 1920x1080`,
`VSR: [DENOISE] … (1:1 denoising)`), colour space preserved:

| Input | Output |
| --- | --- |
| `bt.709/bt.1886` limited | `rgb/bt.709/bt.1886` full |
| `bt.2020-ncl/bt.2020/pq` limited | `rgb/bt.2020/pq` full |

That path normalises range to full and the pixel format becomes packed RGB — the
only format the NGX denoiser accepts. "Passthrough" there means the colour space
survives, not that the frame is bit-identical. `dlssnr` has no such caveat: it
outputs the input's own format and `params.color` is copied through.

## 5. Traps this build hit (do not re-walk these)

1. **`--gpu-context=wayland` is the OpenGL context** and silently falls back to
   `vo=dmabuf-wayland`. The Vulkan one is **`waylandvk`**. The `x2bgr10` interop error
   that looked like a missing libplacebo feature was this.
2. **`hwdec=vulkan` breaks the AI chain.** Vulkan frames cannot be uploaded to CUDA:
   `[hwup] sws_scale failed` → the whole chain disables. The chain needs `hwdec=nvdec`.
3. **`video-params/dolby-vision-profile` does not exist.** That map at
   `player/command.c:2209` is per-**track**. The working property is
   `current-tracks/video/dolby-vision-profile`. A wrong path evaluates to nil and
   `profile-cond` treats nil as false **silently** — the profile never applies and
   nothing is logged. `mpv.conf` already used the track path; `ai.conf` must too.
4. **`profile-restore=copy-equal`, not `copy`.** `profile-cond` properties arrive at
   different moments (height from the track, DV profile from the track list, gamma
   later still), so a profile can apply and deactivate again. With `restore=copy`
   that deactivation restores the *saved empty* `vf` and wipes the chain that just
   took over — observed as `[vsr] init … bits=10` followed by
   `User filter list: (empty)`. `copy-equal` only restores an option that still holds
   the value the profile set, which makes overlapping profiles order-independent.
   Do not change either file back to `copy`.
5. **Do not gate the AI profiles on `video-params/gamma`.** Same race as #4, and the
   reason the original chain gated on height only.
6. **`video-params` is the source, not the filter output.** `gamma` stays `bt.1886`
   for a 1080p SDR file even though the chain emits PQ, so the user's `[HDR]` profile
   does not engage in AI mode. HDR signalling still works: gpu-next raises the
   `VK_EXT_hdr_metadata` / PQ preference from the post-filter PQ frames
   (`target-colorspace-hint=auto` in `mpv.conf`).
7. **`max-fps` on `vfg` is a gate, not a clamp.** A fixed `fps=4:max-fps=110` passes
   the whole thing through; only `fps=auto` adapts K. This is why `ai.conf` ships
   `fps=auto`.
8. **meson forbids `add_project_arguments` after a target is declared** — the VFX
   block must sit before the `add_project_arguments(flags, …)` calls, pushing
   `-I/opt/cuda/include` and the optional rpath into `flags` / `link_flags`.
9. **`find-deps.py` from AUR needs `pactree`** (pacman-contrib), which is not
   installed. Replaced with a self-contained version: `pacman -Qqo` for ownership plus
   one `pacman -Qi` dump for the dependency graph. 26 deps detected, including `cuda`
   and `nvidia-utils`.
10. **`pacman -U --noconfirm` cannot clear a package conflict while sudo owns stdin.**
    Remove the conflicting package first, then install.
11. **`makepkg --builddir` does not exist** (makepkg 7.1.0). Use the `BUILDDIR`
    environment variable, or `makepkg -e` reuses an existing `$srcdir` but then
    `pkgver()` runs in `$startdir` and aborts with `cd: …/arch/src/mpv: No such file`.
12. Cosmetic: the package embeds `$srcdir` strings (FFmpeg's `CONFIGURATION` and
    `libav_internal.h` assert text) — pacman warns, no RUNPATH, harmless.
13. **`vf-command dlssnr …` needs an explicit `@dlssnr:` label.** mpv does not use the
    filter name as its label; it generates `dlssnr.00`, `vfg.00`, … and
    `find_by_label()` (`filters/f_output_chain.c:493`) compares against that. Every
    AI profile therefore writes `@dlssnr:dlssnr:…` / `@vfg:vfg:…`. Without it the
    command returns `error running command` and the filter is never reached — this is
    how the first shipped profiles were wrong.
14. **`PL_COLOR_SYSTEM_DOLBYVISION` is not a YCbCr system.** `matrix_from_repr()` used
    to fall through to `YUV_MATRIX_BT601` for it, so every DV frame decoded with
    Kr=0.299 instead of BT.2020's 0.2624 — a hard red shift in vsr, vfg and truehdr.
    P7/P8 base layers are BT.2020 PQ, so that is now an explicit case in
    `yuv_to_rgba.h`. P5 is ICtCp and no YCbCr matrix is right for it — see §6.
15. **`el_pair` runs after the user chain and re-attaches the RPU.** In
    `filters/f_enhancement_pair.c:102` a BL frame whose `params.no_dovi` is false
    inherits `dovi` from the EL track and is retagged `DOLBYVISION`. Any filter that
    rebuilds a frame in RGB (`vsr`, `vfg`) must set `no_dovi` +
    `no_enhancement_layer`, or libplacebo applies a DoVi reshape to RGB pixels.
    `dlssnr` already did; `vsr` and `vfg` did not.

## 6. Known limits / open items

- **DoVi P7 + `hwup,vfg` asserts on exit**: `vo_gpu_next.c:2507 uninit: Assertion
  p->num_dr_buffers == 0`, so quit produces a core dump instead of a clean exit.
  Playback itself is unaffected. Pre-existing and VFG-specific; not caused by
  `dlssnr` and not fixed.
- **FEL is knowingly lost when NR runs on P7.** `dlssnr` marks its output `no_dovi`
  + `no_enhancement_layer` so `el_pair` drops the EL rather than pairing it with a
  moved base layer. `vsr` and `vfg` set the same flags, so a rebuilt frame is never
  given the RPU back. Keep plain `mpv` (no AI) when FEL detail matters; `dovi=skip`
  keeps FEL and drops NR.
- **P5 is left to libplacebo, with no AI filters** (`ai-*-p5` set no `vf`). P5 is
  ICtCp, not YCbCr: every filter here converts to RGB with a YCbCr matrix, and the
  polynomial/MMR reshape exists only in libplacebo's shader. The earlier policy
  ("only NR is unsafe on P5") was wrong — VSR and VFG corrupted it just as badly.
  P5 now plays exactly as plain `mpv` does. Verified by construction; no P5 sample
  exists in the local corpus.
- **A dead helper now fails over in ~1 frame, not 4 s per frame.** First failure
  still costs the full `timeout` (4000 ms) because that is the only probe available;
  after that `SHM_HELPER_STATE` short-circuits the wait, and three failed frames in a
  row latch `helper_dead` — the filter becomes a passthrough until a seek or reopen.
  Measured: 4 s clip, helper stopped, `spawn=0` → 10 s wall instead of ~6 minutes.
- **`dlssnr` no longer blocks file open on helper launch.** `helper_spawn()` uses
  `posix_spawn` without `waitpid` instead of `system()`; `dlssnr-helper start` brings
  up Python plus a Proton container and used to stall the first frame for seconds.

- **KWin HDR must be ON** for TrueHDR output to reach the panel as HDR. With HDR off,
  the PQ frames get tone-mapped straight back to SDR — use plain `mpv` instead (same
  caveat the `[sdr-to-hdr-itm]` comment in `mpv.conf` already makes).
- **1080p48 is the stress case**: VSR + 2-pass NR + VFG presents ~95 fps with
  `drop≈310–340` over 18 s. `passes=1` there restores 144 fps (drop≈100). 24 fps 2160p
  is comfortable (drop=3 over 20 s).
- **Package depends hard on `cuda` + `nvidia-utils`**: `libnvrtc.so.13` and
  `libcuda.so.1` are real `DT_NEEDED` entries (same as upstream vsr-player's libmpv).
  Removing the CUDA toolkit breaks `mpv` entirely, not just the filters. Making NVRTC
  a lazy `dlopen` would need a source patch + rebuild/retest.
- One VO reconfig at file open (source format → x2bgr10) because the profile engages
  when `video-params` appear. Expected, harmless.
- Browser (Helium) VSR is out of scope here: NVIDIA exposes no Linux equivalent of the
  Windows D3D11 video-processor path that Chromium hooks.
- Do not run a Steam game through the Vulkan layer at the same time — it shares the
  SHM file and the helper.

## 7. Source conventions

- **All comments and log strings are English.** The upstream VSR/VFG/TrueHDR fork
  carried Chinese comments; they were translated on 2026-10-24. Comment-only is
  verified mechanically, not by eye:
  `~/ai-video/build/verify_comments_only.py <baseline-dir> <current-dir> <files…>`
  strips comments and compares code tokens, string-literal count, printf
  specifiers and character literals. It must print `comments/strings only`.
- **Kernel sources are embedded C string literals, one kernel line per literal.**
  Editing a comment inside a kernel string must keep that 1:1 mapping, or the
  generated CUDA source gains/loses a line. The verifier catches this as a
  literal-count mismatch.
- A comment that records a decision carries the date and the measured number.
  "Fixed" without a number is not a comment this codebase keeps.

## 8. Rebuild

```sh
cd ~/ai-video/build/arch
BUILDDIR=~/ai-video/build/makepkg makepkg -f -e --noprepare --check
sudo pacman -U mpv-dovi-vfx-git-0.41.0_1275_g488fec0789-5-x86_64.pkg.tar.zst
```

`-e` reuses `$srcdir` (keeps the FFmpeg/nasm objects); delete
`src/libplacebo/build-lp` and `src/mpv/build` for a genuinely clean configure. A
ccache-warm rebuild is ~65 s on 16 threads.

`check()` fails the build if the filters are not registered, if libav*/libplacebo
leak in as shared libs, if libmpv exports static-library symbols, or if the DoVi FEL
option disappears.

After editing sources, regenerate the patch from the source tree and update
`sha256sums`:

```sh
cd ~/ai-video/build/src/mpv && git add -A && git diff --cached > /tmp/new.patch
cd /tmp && rm -rf pristine && git -C ~/ai-video/build/src/mpv worktree add -f pristine 488fec0789
cd /tmp/pristine && patch -Np1 --dry-run -i /tmp/new.patch   # must print no rejects
```

## 9. Related documentation

- `~/ai-video/DLSS5-NR-PLAN.md` — **design of record for DLSS 5 NR**: runtime
  constraints, the composite, every measured number, known defects.
- `~/ai-video/PLAN.md` — earlier plan, **superseded** (assumed the bundled `mpv-vsr`
  player, which was rejected: filters are grafted into the real mpv instead).
- `~/ai-video/FORK-HDR.md` — NeuralScreen-Linux HDR fork work, still blocked on the
  Phase 0 probes; unrelated to this build.
