# NVIDIA AI video chain for mpv (Linux)

Four NVIDIA NGX filters compiled into mpv, plus **DLSS 5 noise reduction** as an
in-chain filter, driven by a profile set that picks the right chain per source.

Built for an Arch / KDE Wayland desktop with an RTX 5070 and a 2560×1440 165 Hz
panel. Nothing here is Windows-specific; the only Wine dependency is the NR
helper (NGX feature 18 is D3D12-only on Linux).

```
nvdec  ->  hwup  ->  [vsr]  ->  truehdr  ->  dlssnr  ->  vfg  ->  gpu-next
           CUDA    4/3      SDR->HDR10   DLSS 5 NR    frame
           upload  upscale  (passthrough  (2 passes)   generation
                             on PQ/HLG)
```

Order is load-bearing: **NR runs before frame generation**. A present-stage layer
cannot do that (it would denoise interpolated frames), which is why NR is a
filter and not a Vulkan layer.

## What is in here

| Path | What |
| --- | --- |
| `vfx-filters.patch` | The whole change: 22 files against mpv `488fec0789e5026804ac8dd03fb749570416d48a` |
| `PKGBUILD`, `mpv.install`, `find-deps.py` | Arch package that builds mpv + static libplacebo + static FFmpeg + the filters |
| `ai.conf` | Six auto profiles (resolution band × Dolby Vision P5 state) + `[ai]` |
| `docs/AI-CHAIN.md` | Operation manual: resolution/DoVi policy, trap list, rebuild |
| `docs/DLSS5-NR-PLAN.md` | Design of record for the NR filter: constraints, composite, every measured number |
| `tools/verify_comments_only.py` | Proves a source edit changed only comments/strings (used for the English pass) |

## Requirements

- **Arch Linux** (the PKGBUILD is Arch-specific; the patch itself is not).
- **RTX 50-series (Blackwell)** for DLSS 5 NR — NGX feature 18. VSR / TrueHDR /
  VFG work on older NGX-capable cards; `dlssnr` does not.
- **NVIDIA driver** tested on 615.78.08. The package hard-depends on `cuda` and
  `nvidia-utils` because `libnvrtc.so.13` and `libcuda.so.1` are real
  `DT_NEEDED` entries — removing the CUDA toolkit breaks `mpv`, not just the
  filters.
- **`dlssnr-helper`** from [bmitch87/DLSS5VKLayer](https://github.com/bmitch87/DLSS5VKLayer)
  (0.3.1-2, Windows runtime under Proton). It is a shared-memory server; the
  Linux filter is the client. It must be running before playback:

  ```
  ~/.local/bin/dlssnr-helper start | status | stop
  ```

  Without it, `dlssnr` fails open — it logs and stays inert, playback continues.
  From `pkgrel 5` that costs about one frame, not one timeout per frame: the
  filter short-circuits on the shared-memory helper state and latches to
  passthrough after three consecutive failures.

## Build and install

```sh
git clone https://github.com/HyperRamzey/mpv-nvidia-ai-chain
cd mpv-nvidia-ai-chain
makepkg -f --check
sudo pacman -U mpv-dovi-vfx-git-*.pkg.tar.zst
```

The patch applies to the pinned mpv commit with zero rejects:

```sh
git clone https://github.com/mpv-player/mpv && cd mpv
git checkout 488fec0789e5026804ac8dd03fb749570416d48a
patch -Np1 --dry-run -i ../vfx-filters.patch
```

`check()` fails the build if the filters are not registered, if libav*/libplacebo
leak in as shared libraries, if libmpv exports static-library symbols, or if the
Dolby Vision enhancement-layer option disappears.

## Use

```sh
mpv-ai movie.mkv        # the whole chain, profile picked from the source
mpv-nr movie.mkv        # VSR denoiser at 1:1 only
mpv movie.mkv           # untouched player, Dolby Vision as before
```

Live tuning needs the filter's label; a bare `vf-command dlssnr …` fails because
mpv generates `dlssnr.00`, not `dlssnr`:

```sh
vf-command @dlssnr: passes 1
vf-command @vfg: fps 3
```

`mpv-ai` is one line:

```sh
exec mpv --include="$HOME/.config/mpv/ai.conf" --profile=ai "$@"
```

## Policy the profile set encodes

**Resolution** (panel 2560×1440):

| source height | chain |
| --- | --- |
| ≤ 1080 | VSR at 4/3 (1080p → 1440p, 720p → 960p) |
| 1080–1440 | passthrough, no VSR |
| > 1440 | shader downscale to panel first (`dscale=mitchell`), then the AI filters |

Every AI filter works at or below panel resolution. `dlssnr:size=panel` latches
to the display size and only ever shrinks; the model itself sees
`work_scale × panel`.

**Dolby Vision:**

| input | NR | note |
| --- | --- | --- |
| P7 (FEL/MEL), P8.1 | runs | EL is knowingly dropped (`no_dovi` + `no_enhancement_layer`) |
| P5 (IPTPQc2) | never runs | no filters at all — native libplacebo DoVi path |
| 2160p DV | runs | no VSR; the downscale to panel happens inside the AI filters |

P5 is ICtCp, not YCbCr, so *any* filter that round-trips through RGB corrupts it —
`vsr` and `vfg` as much as `dlssnr`. The three `*-p5` profiles therefore set no
`vf` and play exactly like plain `mpv`.

**Frame generation:** `vfg:fps=auto:max-fps=110`. VFG only does integer
multipliers, and the right K is a function of source fps *and* panel refresh, so
the filter picks the largest K in 2..4 that fits under the cap and passes through
only when none does. The cap is 110, not 165, because the chain's presentation
ceiling with 2-pass NR is ~96–100 fps.

## Measured on the reference machine

| test | result |
| --- | --- |
| throughput, 2160p48 → 1440p (`--untimed`) | `hwup` 65.5 fps · `dlssnr:passes=2` 40.7 fps · cinematic ws0.5 43.0 fps · ws1.0 22.2 fps |
| NR cost at 1440p work size | 14.7 ms (1 pass) / 25.4 ms (2 passes) |
| playback, 2160p48 DV P7 | 96 fps out, drop 84–120 over 18 s |
| playback, 2160p24 DV | 96 fps out, drop 3 over 20 s |
| playback, 1080p48 SDR (VSR + NR) | ~95 fps out, drop 310–340 over 18 s (worst case) |
| preset strength, mean \|Δ\| vs `passes=0` | faithful 2.51 · cinematic ws1.0 4.63 · cinematic ws0.5 5.46 codes |

NR is delta-composited: the model returns an 8-bit SDR proxy of the frame, and
only its **difference** is upscaled and added back to the pristine native frame.
The anchor is never replaced, so text and edges keep full resolution.

## Known issues

1. **Dolby Vision + `hwup,vfg` asserts on exit**: `vo_gpu_next.c:2507 uninit:
   Assertion p->num_dr_buffers == 0`, so quitting produces a core dump instead of
   a clean exit. Playback is unaffected; it is VFG-specific and predates
   `dlssnr`.
2. **FEL detail is lost when NR runs** on P7 — by design. Use plain `mpv` when
   FEL matters, or `dlssnr:dovi=skip` to keep FEL and drop NR.
3. **P5 gets no AI at all.** ICtCp has no correct YCbCr matrix in this chain, so
   the `*-p5` profiles hand the file to libplacebo untouched. Verified by
   construction; no P5 sample exists in the local corpus.
4. **1080p48 with VSR is the stress case** (~310–340 dropped frames / 18 s).
   `dlssnr:passes=1` there restores 144 fps.
5. **The NR answer buffer is allocated per frame** (14.7 MB `cuMemAlloc`, freed
   on the VO thread). Within budget, but a persistent buffer is the obvious next
   optimisation.

## Correctness fixes in this revision

`pkgrel 5` (patch sha256 `9d755ffb…`) closes four defects found by reading the
whole chain, not just the new filter:

| defect | fix | measured |
| --- | --- | --- |
| DV base layers decoded with BT.601 — `matrix_from_repr()` had no DoVi case, so Kr was 0.299 instead of 0.2624 (red shift) | explicit `PL_COLOR_SYSTEM_DOLBYVISION` → BT.2020 | full chain at `passes=0` vs native `mpv`, 2160p P7: mean 0.017 codes, p99 1, max 7 |
| `vsr` / `vfg` emitted RGB frames that `el_pair` re-tagged as DoVi, applying a reshape to RGB | set `no_dovi` + `no_enhancement_layer`; `hwup` keeps the `dovi` reference across SW→HW | full chain mean Δ 3.55 codes, matching the measured cinematic preset (4.63) with no channel bias |
| a stopped helper cost one 4 s timeout per frame forever | fail-fast on `SHM_HELPER_STATE`, latch to passthrough after 3 failures | 4 s clip: 10 s wall instead of ~6 min |
| helper launch blocked file open (`system()`) | `posix_spawn` without `waitpid` | first frame no longer stalls |

## License

`vfx-filters.patch` modifies mpv and is distributed under the same terms as mpv
(GPLv2 or later). `PKGBUILD` and the docs are provided as-is, no warranty.
Dolby Vision handling relies on libplacebo 7.377 with libdovi; NGX itself is
NVIDIA's, shipped with the driver.
