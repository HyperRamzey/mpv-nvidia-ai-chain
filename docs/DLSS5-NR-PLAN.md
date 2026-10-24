# DLSS 5 NR (NGX feature 18) for mpv — design of record

Status: **implemented, packaged and installed.** `vf_dlssnr` ships in
`mpv-dovi-vfx-git 0.41.0_1275_g488fec0789-5` alongside `vf_vsr`, `vf_truehdr`,
`vf_vfg` and `vf_hwup`; `~/.config/mpv/ai.conf` is the shipped profile set.
Sections 1–3 are the design as researched; §4–§7 are what actually got built and
what it measured. Every number below is measured on this machine unless marked
otherwise.

Target: 2160p Dolby Vision P7 FEL (`/mnt/aosp/upscale/Charles_DV7.mkv`), RTX 5070,
NVIDIA 615.78.08, 2560×1440 panel.

---

## 1. What the runtime actually is

DLSS 5 **NR** is NGX **feature 18**, `nvngx_dlssnr.dll`. It is D3D12-only, so on Linux it runs
in a Windows helper under Proton (`dlssnr-helper`, from `bmitch87/DLSS5VKLayer` 0.3.1-2, imported
runtime `nvngx_dlssnr.dll` sha256 `e16bcf15…` = NVIDIA-signed 310.8 for Blackwell).

The helper is a plain shared-memory server: `$XDG_RUNTIME_DIR`-adjacent file
`/tmp/dlssnr-$UID/shm.bin` = 64 KiB header + two frame regions (max 7680×4320×8 B), plain atomics.

```
client:  write proxy px → seq_req++        helper: sees seq_req > seq_resp
         spin on seq_resp >= seq_req               encodes/uploads → NGX Evaluate ×passes
                                                   → writes answer px → seq_resp = req, seq_ok
client:  read answer px
```

Verified working: `shm_bench` drives it, `helper_frames` increments.

### Hard constraints (measured, not assumed)

| Fact | Evidence |
|---|---|
| Model refuses the HDR/float16 create | `GetFeatureRequirements -> 0xbad00005`, `create contract … hdr=0` even with `hdrmode 2` forced, `proxy_format=1` |
| So every frame crosses as **8-bit RGBA, SDR** | same, plus `tonemap hint: SDR (featureFlags=0)` |
| **Output size == input size.** No internal rescale to native | feature is created at the header's `w×h`; the answer occupies the same raster. `workingScale` is a *layer-side* concept, it scales around the exchange, NGX does not do it for us |
| One NGX feature **per pass** | `VULKAN_CreateFeature(18) pass 0`, `pass 1` in the helper log |

Consequence: the user-facing "internal scaling 50–100%" is implemented **by us** — we hand the
model `work_scale × panel` and put the result back ourselves. There is no free lunch inside NGX.

## 2. Verified cost on the RTX 5070 (RTX 5070, 8-bit proxy, style cinematic, round trip incl. transport)

| work size | 1 pass | 2 passes |
|---|---|---|
| 1280×720 | 8.5 ms | — |
| 2560×1440 | 14.7 ms (68 fps) | 25.4 ms (39 fps) |
| 3840×2160 | 30.4 ms (33 fps) | 53.9 ms (18.5 fps) |

So **2160p × 2 passes is 18.5 fps — below 24.** Everything must be ≤ panel res. At 1440p,
2 passes leaves ~14 ms of the 24 fps budget for decode, downscale, composite and FG.

Cross-check, NeuralScreen's own fit (D3D12, evaluate-only): `1.50 ms + 1.51 ms/MPix` → 7.1 ms at
1440p. Ours is 14.7 ms because it includes the SHM round trip and their composite.

## 3. How NeuralScreen does it (the reference we port)

### Ordering
`capture → NR (1–4 passes @ work res) → matched-residual composite → FG → present`.
NR before FG. FG is DLSSG (`nvngx_dlssg.dll`), ×2–×6. **It does not use DLSS SR for upscaling**
— the only "NGX upscaling" in its code is *motion-field* upscaling.

### Passes
- `nr_passes` 1–4, default 1.
- **Each pass gets its own NGX feature** — calling one feature twice in a frame lies to its
  temporal history.
- VRAM at 1440p work size: 845 MB for 1 pass, +637–893 MB per extra pass.
- 2nd pass costs ~1/3 of the frame rate (our measurement: 14.7 → 25.4, 1.73×).
- **Passes ≥2 run with `local_tone = 0`** unless overridden: tone stacks and darkens
  (mean luma 0.988 / 0.978 / 0.970 at 1/2/3 passes; 0.988 flat with tone 0).
  Our helper does **not** do this — `ShmResolvePass()` just merges globals with overrides,
  so we must set it per pass ourselves.
- Passes ping-pong two scratch buffers; parity picks the start so the last pass lands in `nr_out`.

### Profiles (exact)
| profile | style | intensity | local_tone | local_structure | skin |
|---|---|---|---|---|---|
| Faithful | 0 | 0.70 | 0.25 | 0.75 | −1 |
| Natural | 1 | 1.00 | 0.50 | 1.00 | −1 |
| **Strong / Cinematic** | **2** | **1.00** | **0.90** | **1.50** | **1.0** |
| Extreme / Overdrive | 2 | 1.00 | 1.50 | 1.50 | 1.5 |

`style` is `{0 Default, 1 Natural, 2 Cinematic}`; `preset` is the model's own render preset, 0–15.

### Which settings latch when
`style`, `preset`, `intensity`, `local_tone`, `local_structure`, `skin_structure`, `auto_mask`
are read **once, when that pass's feature is built** (a change = rebuild, ~120 ms/pass).
`sharpness` is the only one read **at evaluate**.

### The residual composite
```
result = anchor + (upscaled_delta)            # never the model's frame itself
delta  = nr_out - nr_in
```
The pristine native frame stays the anchor: text/edges keep full resolution while the cheap
low-res network contributes only its delta. Measured on a synthetic detail pattern: Laplacian
detail 983 vs 88 for a plain bilinear upscale.

### HDR — the part that matters most
**NeuralScreen never runs the model in HDR.** The model always receives an SDR 8-bit proxy; only
the delta comes back, and it is re-expanded by the anchor's own magnitude (`native/hdr_shaders.h`):

```hlsl
// capture encode
c = ToSrgb(max(c.rgb, 0) / (white + Peak(c.rgb)));

// composite, on the 1:1 native HDR frame
result = original + (white + Peak(original)) * clamp(b - a, -.25, .25);
```

"No inverse tone mapping: it becomes singular near white." The per-pixel gain `white + Peak(·)` is
computed from the same pixel on both ends, so the delta is **scale-relative** and the target's
range is preserved exactly. The delta is applied in display space, deliberately — they note the
error is largest in the darkest pixels.

Our PQ port of the same pair:
```
L  = PQ_EOTF(code)                      # 1.0 = 10000 nits
w  = 0.0203                             # 203-nit paper white, = kPqPaperWhite in the layer
den = w + peak(L)
a  = srgb_encode(L / den)               # 8-bit proxy → model
b  = model(a)
L' = L + den * clamp(b - a, ±0.25)
code' = PQ_OETF(L')
```
For SDR the identical code path with `den = 1.0` and bt.1886 in place of PQ.

## 4. The pipeline we build

```
2160p source (CUDA frames, nvdec)
  │
  ├─ shader downscale to panel res (2160→1440) — SSimDownscaler / mitchell
  │     (user's mpv.conf: dscale=mitchell, linear-downscaling=no, correct-downscaling=yes)
  │
  ├─ vf_dlssnr @ 1440p
  │     proxy encode (SDR: bt.1886 → 8-bit · HDR: PQ → 8-bit, see §3)
  │     NR ×2 passes, cinematic, work_scale 50–100%, local_tone=0 on pass 2
  │     residual composite back onto the 1440p anchor
  │     output: 1440p, same params as input
  │
  ├─ vf_vfg ×4        ← FG strictly after NR
  │
  └─ libplacebo present 1:1 at 2560×1440
```

Everything ≤ panel res; nothing is ever processed at 2160p except the shader downscale.

### DoVi matrix (what the chain can and cannot keep)
| source | in-chain NR | note |
|---|---|---|
| SDR bt.709/1886 | ✔ exact | |
| HDR10 / PQ | ✔ | residual composite preserves the range |
| DoVi **P8.1** | ✔ | = HDR10 + RPU; RPU not consumed in-chain |
| DoVi **P7** | ✔ as BL | EL only consumed by libplacebo at present → **EL lost** once any in-chain filter runs. Known and accepted |
| DoVi **P5** | ✘ not attempted | ICtCp, not YCbCr. No AI filter runs on it — see below |

P5 is handled **by policy in `ai.conf`, not inside the filter**. The three `-p5`
profiles set no `vf` at all: playback falls through to libplacebo's native DoVi
path, byte-for-byte what plain `mpv` does.

The earlier policy here was wrong. It skipped NR on P5 but kept VSR and VFG on the
theory that only the residual composite was domain-sensitive. P5 is **ICtCp**, not
a YCbCr encoding: `matrix_from_repr()` cannot produce a correct RGB conversion for
it (`PL_COLOR_SYSTEM_DOLBYVISION` is only right for the P7/P8 BT.2020 base layers),
and the IPTPQc2 polynomial/MMR reshape exists only in libplacebo's shader. So *any*
in-chain filter that round-trips through RGB destroys P5 — VSR and VFG as much as
NR. The only correct chain is no chain.

Policy is sufficient here because the profile number is readable from
`current-tracks/video/dolby-vision-profile` (trap in §6); no per-frame detection
inside the filter is needed. Verified by construction — there is no P5 sample in
the local corpus.

## 5. Settings surface as implemented

Filter options on `vf_dlssnr` (the real list, from `vf_opts_fields`):

| option | range / values | default | meaning |
|---|---|---|---|
| `passes` | 0–4 | 2 | 0 = filter inert (the no-NR reference used for every measurement) |
| `profile` | faithful natural cinematic extreme custom | cinematic | the §3 table |
| `style` `intensity` `localtone` `localstructure` `skin` `sharpness` `automask` `preset` | NeuralScreen ranges | −1000 / sentinel | per-setting override; sentinel = take it from `profile` |
| `override2` `override3` `override4` | `key=val;key=val` string | unset | per-pass override, e.g. `override2=localtone=0` |
| `work_scale` | 0.25–1.0 | 0.5 | "internal scaling": the proxy is this fraction of the panel-res anchor |
| `size` | panel \| native | panel | `panel` = latch to display size, **shrink only**; `native` = whatever the filter receives |
| `filter` | mitchell catmull bilinear | mitchell | residual upscale kernel (was hardcoded Catmull-Rom before) |
| `detail` `guard` | 0–4 / 0–1 | 1.0 / 0.25 | residual gain / clipping guard |
| `blackgate` | 0–64 | 8 | fade the residual out below N proxy codes (see §6) |
| `white` | 50–10000 nits | 203 | `w` in the composite, i.e. paper white |
| `timeout` | 20–120000 ms | 4000 | per-frame SHM wait |
| `mvec` `mvec_quality` | 0–1 / 0–2 | 1 / 1 | optical-flow hints for the model |
| `sdr16` | −1/0/1 | −1 | `sdr16Multipass`; auto-on when `passes ≥ 2` |
| `spawn` `shm` | 0–1 / path | 1 / auto | start the helper if absent / override the SHM path |
| `dovi` | run \| skip | run | `skip` = pass DoVi frames through untouched |
| `verbose` | 0–1 | — | per-frame logging |

There is deliberately **no `target` / `dscale` / `upscale` / `mode`** option: the
target is the panel (or the incoming size), the kernel is `filter`, and the
colour mode is detected per frame from `params.repr.sys` rather than configured.
Options that NeuralScreen has but that only make sense inside a D3D12 present
hook (its own DLSSG call, its capture format) are not exposed.

Runtime control without restarting playback: `vf-command @dlssnr: <opt> <val>`
(the label is load-bearing — see the trap in §6),
and `dlssnr-status:` prints once a second (`passes=2 work=1280x720 cost=14.5ms
fps=48 fails=0`). `DLSSNR_DUMP=<dir>` writes the proxy/anchor/answer planes for
offline comparison — that is how every delta number in §6 was obtained.

## 6. What shipped, and what it measured

### Implementation

`video/filter/vf_dlssnr.c` (filter shell, options, SHM client, helper spawn,
status line) + `video/filter/dlssnr_proc.{c,h}` (NVRTC kernels run on the CUDA
context that `vf_hwup` establishes). `vfx-filters.patch` is the deliverable of
record: 8527 lines, 22 files, applies to a pristine
`488fec0789e5026804ac8dd03fb749570416d48a` with zero rejects.

Frame path inside the filter:

```
YUV (any of NV12/P010/P016, cuda[])  -> RGB float, linear light
  anchor  = filter_in resized to panel (size=panel latch, shrink only)
  proxy   = anchor resized by work_scale, encoded to 8-bit SDR
  answer  = NGX feature 18 x passes          (per-pass NGX feature, as NeuralScreen)
  delta   = upscale(answer - proxy) x filter  (Mitchell by default)
  out     = anchor + den * delta, den = 1 (SDR) / white + peak(L) (PQ/HLG)
  -> back to the input's own YUV format and colours
```

Colour: `params.color` is copied through untouched, so output colour space
equals input colour space by construction. On DoVi input the output is marked
`no_dovi` **and** `no_enhancement_layer`, so the post-filter `el_pair` drops the
EL instead of trying to pair it with a base layer that has moved.

### Bug found and fixed during bring-up: the SDR curve

`decode3`/`encode3` were initially a bare `pow(x, 2.4)`. Against a measured
reference that is wrong: the round trip has to be the **sRGB** curve
(piecewise: linear toe below 0.04045, 2.4 power above). With the bare power the
mid-tones sat ~2 codes low and the picture read as flat. After the change
`out == enc(anchor + delta)` matches to **0.18 codes** over the full ramp, i.e.
quantisation only.

### Bug found and fixed during bring-up: black pedestal

The model returns a small positive residual wherever its input was black —
measured **+3.7 codes** on the P7 letterbox, 0.436 nits of grey that was not in
the source. `blackgate=N` (default 8) fades the residual out below N proxy
levels; above the knee it is exactly NeuralScreen. Measured on the P7 letterbox:
code 0 → 0.0002 nits (from 0.436), code 4 still measures 4 codes, and
`blackgate=0` reproduces NeuralScreen byte for byte (and brings the 0.436-nit
bar back). `blackgate` is two per-pixel comparisons and a ramp, dwarfed by the
NGX evaluate itself.

### Preset strength (identical P7 frames, 40+, vs a `passes=0` render)

| chain | mean \|delta\| (codes) | luma std | Laplacian |
|---|---|---|---|
| faithful | 2.51 | −5.1 % | +23.0 % |
| cinematic, work_scale 1.0 | 4.63 | −10.7 % | +36.9 % |
| cinematic, work_scale 0.5 | 5.46 | −11.3 % | +42.7 % |

`work_scale=0.5` is *stronger* than 1.0 in the numbers but visibly worse: a
smeared badge and blotchy wall, because the residual is resampled. So 1.0 is the
quality choice and 0.5 the throughput choice — 22.2 fps vs 43.0 fps on 2160p48
input (`--untimed`, into 1440p). `hwup` alone is 65.5 fps; `dlssnr:passes=2`
alone is 40.7 fps.

### Two passes are ~one pass

Pass 1 differs from pass 0 in **0.1 % of bytes**. Pass 0 (`localtone=0.9`)
carries the work; pass 1 is near-identity. `passes ≥ 2` is still the default
because it enables `sdr16Multipass` (SHM offset 1960), the documented mitigation
for 8-bit hue ping-pong, and because a second evaluate hides single-pass
temporal noise. Cost is real: 14.7 → 25.4 ms at 1440p work size.

### Playback ceiling — why the FG cap is 110, not 165

18-second runs, `drop` = `frame-drop-count`:

| input | chain | drop |
|---|---|---|
| 2160p48 DV P7 | `hwup,vfg:fps=3` | 24 |
| 2160p48 DV P7 | `hwup,dlssnr:2,vfg:fps=3` | 1055 |
| 2160p48 DV P7 | `hwup,dlssnr:2,vfg:fps=2` | 84–120 |
| 2160p48 DV P7 | `hwup,dlssnr:1,vfg:fps=3` | 100 |
| 2160p24 DV 3754×1854 | `ai-big` (k=4) | 3 |
| 1080p48 SDR | `ai-vsr` (VSR + 2 NR + k=2) | 308–342 |
| 2160p48 HDR10 | `ai-big` | 13 |

The chain presents ~95–100 fps with 2-pass NR, not 144. `max-fps=110` keeps
`fps=auto` inside the measured-clean region; `passes=1` buys back 144.

### `fps=auto` in `vf_vfg`

VFG only does integer multipliers, so a fixed K is wrong for some inputs: 48 fps
×4 = 192 on a 165 Hz panel measured `drop=3490` in 15 s, ×3 = 144 measured
`drop=22`. The multiplier is a function of source fps *and* panel refresh, so it
belongs in the filter, not in a config. `fps=auto` (`VFG_FPS_AUTO 0`) picks the
largest K in 2..4 that fits under `max-fps`; with no cap or unknown `src_fps` it
behaves like the old default (×4). Verified: 24 → k=4, 48 → k=3, 120 →
`mode=passthrough reason=max-fps`, 3754×1854@24 → k=4. `print`/`vf-command fps
auto` round-trip. An explicit 2/3/4 keeps the old gate semantics exactly.

### Config traps worth recording

- **`video-params/dolby-vision-profile` does not exist.** The map at
  `player/command.c:2209` is the per-track map; `video-params/dolby-vision-profile`
  evaluates to nil, and `profile-cond` treats nil as false *silently* — the
  profile simply never applies. The property is
  `current-tracks/video/dolby-vision-profile`.
- **`profile-restore=copy-equal`, not `copy`.** The DV profile number arrives
  from the track list while `h` is already known, so the non-DV profile can
  apply first and deactivate a moment later. With `copy` that deactivation
  restores the saved (empty) `vf` and wipes the chain that just took over — the
  "no filters at all" bug. `copy-equal` only restores an option still holding
  the value the profile set.
- **`vf-command` needs the `@label:` form.** mpv does not use the filter name as
  its label; unlabelled filters get generated labels (`dlssnr.00`, `vfg.00`) and
  `find_by_label()` compares against those. Every AI profile therefore writes
  `@dlssnr:dlssnr:…` / `@vfg:vfg:…`. Without the label `vf-command dlssnr passes 1`
  returns `error running command` and nothing happens.
- **`PL_COLOR_SYSTEM_DOLBYVISION` is not a YCbCr system.** `matrix_from_repr()`
  fell through to `YUV_MATRIX_BT601` for it, so DV base layers decoded with
  Kr=0.299 instead of BT.2020's 0.2624 — a hard red shift in `vsr`, `vfg` and
  `truehdr`. P7/P8 are BT.2020 PQ and now have an explicit case.
- **`el_pair` re-attaches the RPU after the user chain.** A base-layer frame whose
  `params.no_dovi` is false inherits `dovi` from the EL track and is retagged
  `DOLBYVISION`. Any filter that rebuilds a frame in RGB must set `no_dovi` +
  `no_enhancement_layer`, or libplacebo applies a DoVi reshape to RGB pixels.

### Shipped profile set (`~/.config/mpv/ai.conf`)

Six mutually exclusive profiles, all `profile-restore=copy-equal`:

| profile | condition | chain |
|---|---|---|
| `ai-vsr` | h ≤ 1080, not P5 | `hwup,vsr:scale=4/3,truehdr,dlssnr:2:cinematic:ws.5,vfg:auto:110` |
| `ai-vsr-p5` | h ≤ 1080, P5 | **no `vf`** — native DoVi path |
| `ai-mid` | 1080 < h ≤ 1440, not P5 | no VSR |
| `ai-mid-p5` | 1080 < h ≤ 1440, P5 | **no `vf`** — native DoVi path |
| `ai-big` | h > 1440, not P5 | no VSR, downscale first |
| `ai-big-p5` | h > 1440, P5 | **no `vf`** — native DoVi path |

`[ai]` sets `hwdec=nvdec` (mandatory: `hwdec=vulkan` yields Vulkan images that
`hwup` cannot upload — `sws_scale failed`, whole chain disables).

Verified on the installed binary: 1080p SDR → `ai-vsr`; P7 2160p48 and HDR10
2160p48 → `ai-big` with `truehdr-status: mode=passthrough` on the HDR10 one;
`dlssnr-status` and `vfg-status` present in all three; no mid-playback profile
flip.

### Fixes from the chain audit (pkgrel 5)

Everything above was shipped in `-4`; `-5` closes the defects a full read of the
chain turned up. Patch size 8399 → 8527 lines, sha256 `9d755ffb…`.

| defect | fix | evidence |
|---|---|---|
| DV base layers decoded with BT.601 (`matrix_from_repr` fell through) | explicit `PL_COLOR_SYSTEM_DOLBYVISION` → `YUV_MATRIX_BT2020` in `yuv_to_rgba.h`; the now-redundant inline override in `vf_dlssnr.c` removed | full chain with `passes=0` vs native `mpv` on 2160p P7: **mean 0.017 codes, p99 1, max 7** — bit-identical for practical purposes |
| `vsr` / `vfg` produced RGB frames that `el_pair` re-tagged as DoVi | both set `no_dovi` + `no_enhancement_layer`; `vf_hwup`'s SW→HW path now `av_buffer_ref`s `dovi` and repoints `params.repr.dovi` | full chain mean delta 3.55 codes vs native, matching the measured cinematic-preset strength (4.63) with no channel bias (R−G 3.90 vs 3.77) |
| dead helper cost one `timeout` per frame forever (≈6 min for a 4 s clip) | first failure still costs the timeout; afterwards `SHM_HELPER_STATE` short-circuits the wait; 3 consecutive failures latch `helper_dead` → passthrough until seek/reopen | helper stopped + `spawn=0`, 4 s clip → **10 s wall**, `3 failed frames in a row -- NR disabled for this file`, exit 0 |
| `helper_spawn()` used `system()`, blocking file open on a Python + Proton launch | `posix_spawn` without `waitpid` | first frame no longer stalls |
| SHM file opened without checks | `O_NOFOLLOW` + `O_CLOEXEC`, owner and regular-file check | — |

## 7. Known defects

1. **DoVi + `hwup,vfg` asserts on exit.** `vo_gpu_next.c:2507 uninit: Assertion
   p->num_dr_buffers == 0` → core dump instead of a clean quit. Pre-existing and
   VFG-specific (the synthesised frame's DR buffer outlives the VO's tracking).
   Playback, presentation and all output before the quit are unaffected. Not
   caused by `dlssnr`; not fixed here.
2. **FEL is lost when NR runs on P7.** By design: `dlssnr` marks its output
   `no_dovi` + `no_enhancement_layer`, and `vsr`/`vfg` set the same two flags, so
   `el_pair` drops the EL rather than pairing it with a moved base layer. Use
   plain `mpv` (no AI) when FEL detail matters; `dlssnr:dovi=skip` on a one-off
   command line keeps FEL and drops NR.
3. **1080p48 is the stress case.** VSR + 2-pass NR + FG presents ~95/s with
   `drop≈310–340` over 18 s: visible but bounded. `passes=1` there if it matters.
4. **Helper is not a service.** `dlssnr-helper start` must run after a reboot;
   without it `dlssnr` fails open (logs, filter inert) rather than crashing, and
   from `-5` that costs ~1 frame of latency instead of one timeout per frame.
5. **The answer buffer is allocated per frame.** `dlssnr_proc_take_out` does a
   14.7 MB `cuMemAlloc` (1280×720 proxy round-trip) per frame and the matching
   `cuMemFree` lands on the VO thread. It works and stays inside the measured
   cost, but it is the obvious next optimisation: a persistent ring buffer.
6. **No P5 sample exists locally.** The P5 policy (native path, no filters) is
   verified by construction — ICtCp has no correct YCbCr matrix in this chain —
   not against real P5 content.

## 8. Reproducing the build

```
cd ~/ai-video/build/arch
BUILDDIR=$HOME/ai-video/build/makepkg makepkg -f -e --noprepare --check
sudo pacman -U mpv-dovi-vfx-git-0.41.0_1275_g488fec0789-5-x86_64.pkg.tar.zst
```

`PKGBUILD` pins the patch by sha256
`9d755ffba67a3be91ed9203e129b5327dd741ac3501b3a93af089883dcf33788`. `-e`
reuses the existing `$srcdir`; delete `src/libplacebo/build-lp` and `src/mpv/build`
first for a genuinely clean configure. `check()` builds and runs mpv's own tests.

## Related documentation
- `~/.config/mpv/ai.conf` — the shipped profile set and the tuning notes
- `~/ai-video/AI-CHAIN.md` — the VSR / TrueHDR / VFG chain this joins
- `~/ai-video/build/arch/PKGBUILD` — the package these filters ship in
