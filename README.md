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
| `scripts/vfg-sync.lua` | Keeps VFG's output cap equal to the current display refresh |
| `extension/` | Chromium MV3 extension: send a page, link or video to the chain |
| `native/` | Native messaging host (Python, stdlib only) + installer |
| `.github/workflows/` | `ci.yml` (fast gates) and `release.yml` (cold makepkg → GitHub release) |
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
  Linux filter is the client. It is only needed when noise reduction is enabled
  (`passes>=1`); the shipped config runs NR off (`passes=0`), which is a true
  passthrough and never talks to the helper:

  ```
  ~/.local/bin/dlssnr-helper start | status | stop
  ```

  Without it, `dlssnr` fails open — it logs and stays inert, playback continues.
  From `pkgrel 5` on, that costs about one frame, not one timeout per frame: the
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

### Prebuilt package (GitHub Actions)

Pushing a `v*` tag runs `.github/workflows/release.yml`: it verifies that
`vfx-filters.patch` still hashes to what `PKGBUILD` pins and still applies to the
pinned mpv commit, then does a cold `makepkg --check` in an
`archlinux:base-devel` container, then publishes the package with the patch,
`PKGBUILD`, `ai.conf` and `SHA256SUMS`. No GPU is needed at build time —
`nvidia-utils` only supplies `libcuda.so` to link against.

```sh
git tag v0.41.0-r6 && git push origin v0.41.0-r6
gh run watch
```

`ci.yml` runs the cheap gates (patch hash, patch dry-run, `py_compile`,
`shellcheck`, JSON validity, `ai.conf` syntax) on every push, so a release is
never the first time a broken patch is noticed.

## Use

```sh
mpv-ai movie.mkv        # the whole chain, profile picked from the source
mpv-nr movie.mkv        # VSR denoiser at 1:1 only
mpv movie.mkv           # untouched player, Dolby Vision as before
```

Install the config and the refresh script once:

```sh
install -Dm644 ai.conf               ~/.config/mpv/ai.conf
install -Dm644 scripts/vfg-sync.lua  ~/.config/mpv/scripts/vfg-sync.lua
```

Noise reduction is **off by default** (`dlssnr:passes=0`, a true passthrough —
the filter returns before any CUDA work, so it costs nothing). Enable it by
changing `passes=0` to `passes=2` in the three `vf=` lines, or for one run:

```sh
vf-command dlssnr passes 2
```

Frame generation follows the panel: `scripts/vfg-sync.lua` watches `display-fps`
and issues `vf-command vfg max-fps <refresh>`, so `fps=auto` picks the largest
integer multiplier (2..4) that fits the current mode. On the 165 Hz mode that is
96 fps for 24 fps sources, 120 for 60 fps, 144 for 48 fps; switch the panel to
120 Hz for 60 fps material if the 165 Hz pacing shows. Measured with NR off,
10 s each, drop = `frame-drop-count`: 1080p60+VSR → 120 fps / 1 drop, 2160p60 →
120 fps / 0 drops, 1080p48 → 144 fps / 4 drops, 2160p24 → 96 fps / 0 drops.

Live tuning addresses a filter by its chain label, written without the `@` that
marks it in `vf=` (`@dlssnr:dlssnr:…` is addressed as `dlssnr`):

```sh
vf-command dlssnr passes 1
vf-command vfg fps 3
vf-command vfg max-fps 120
```

`mpv-ai` is one line:

```sh
exec mpv --include="$HOME/.config/mpv/ai.conf" --profile=ai "$@"
```

## Browser extension (Chromium / Helium)

Click the toolbar icon, press <kbd>Alt</kbd>+<kbd>Shift</kbd>+<kbd>M</kbd>, or
right-click a page / link / video and pick **Send to mpv**. The browser hands the
URL to a native host, the host starts `mpv-ai` (or `mpv-nr`, or plain `mpv`)
detached in its own session, and the AI chain does the rest — YouTube URLs go
through yt-dlp, which mpv's own `ytdl_hook` already drives.

Install once:

```sh
# 1. register the host (copies it to ~/.local/share/mpv-ai-extension)
./native/install_native_host.sh

# 2. load the extension
#    helium-browser chrome://extensions -> Developer mode -> Load unpacked
#    -> select the extension/ directory
```

The manifest embeds an RSA public key, so the extension ID is
`laaljncfmpifjkegkcolkmifmbdpkece` for everyone — that is what the installer
writes into `allowed_origins`, and it does not change when the checkout moves.
Re-run the installer after editing `native/mpv_ai_host.py`; it copies the file
and then round-trips a `ping` through the installed host to prove it works.

Options (right-click the icon → Options) set the default profile, whether to
start fullscreen, extra mpv arguments, and a `--ytdl-format`. The right-click
menu overrides the profile per launch. Feedback is the toolbar badge: `OK` on a
successful spawn, `!` on failure, with the reason in the service-worker console
and in `~/.local/state/mpv-ai-extension/launch.log`.

Three things worth knowing:

- The host only accepts `http(s)` URLs and only ever starts one of three fixed
  programs; there is no shell in the path.
- Playback is detached: closing the browser or the tab does not stop mpv.
- `mpv-ai` needs a GPU video output. `--vo=null` with the chain segfaults (the
  filters require the VO's CUDA context); plain `mpv --vo=null` is fine.

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

`pkgrel 6` (patch sha256 `8e487d9f…`) closes eleven defects found by reading the
whole chain, not just the new filter. The first four:

| defect | fix | measured |
| --- | --- | --- |
| DV base layers decoded with BT.601 — `matrix_from_repr()` had no DoVi case, so Kr was 0.299 instead of 0.2624 (red shift) | explicit `PL_COLOR_SYSTEM_DOLBYVISION` → BT.2020 | full chain at `passes=0` vs native `mpv`, 2160p P7: mean 0.017 codes, p99 1, max 7 |
| `vsr` / `vfg` emitted RGB frames that `el_pair` re-tagged as DoVi, applying a reshape to RGB | set `no_dovi` + `no_enhancement_layer`; `hwup` keeps the `dovi` reference across SW→HW | full chain mean Δ 3.55 codes, matching the measured cinematic preset (4.63) with no channel bias |
| a stopped helper cost one 4 s timeout per frame forever | fail-fast on `SHM_HELPER_STATE`, latch to passthrough after 3 failures | 4 s clip: 10 s wall instead of ~6 min |
| helper launch blocked file open (`system()`) | `posix_spawn` without `waitpid` | first frame no longer stalls |

The second pass added:

| defect | fix | measured |
| --- | --- | --- |
| all five filters dropped `params.rotate`, `vflip`, `stereo3d`, `fields`, `pkt_duration` | copied onto every rebuilt frame (VFG keeps its synthetic duration) | 90° display matrix through `ai-vsr`: **2560×1440 before, 1440×2560 after**, native `mpv` 1080×1920 |
| NR's "3 failed frames in a row" latch was never reset by a success — three failures anywhere disabled it | reset `fail_count` after a good frame | dead-helper test unchanged: 4 s clip → 9.5 s wall |
| engine teardown synced stream 0, the exact call its own comment bans (Xid 109 deadlock) | removed; only the engine stream is synced | quit during playback and at EOF still clean |
| `truehdr` kept its permanent-passthrough latch across a seek | `f_reset` clears it | code path |
| `dlssnr`'s YUV kernel cache ignored the input depth (P010 vs P016) | added to the cache key | — |
| `hwup` wrote `h/2` chroma rows, leaving one uninitialised for odd heights | `ceil(h/2)` | — |

## License

`vfx-filters.patch` modifies mpv and is distributed under the same terms as mpv
(GPLv2 or later). `PKGBUILD` and the docs are provided as-is, no warranty.
Dolby Vision handling relies on libplacebo 7.377 with libdovi; NGX itself is
NVIDIA's, shipped with the driver.
