# CRT beam simulator (rolling scan) for the AI chain

Implements Blur Busters' CRT Beam Simulation on top of the finished chain: after
`hwup → dlssnr → vsr → truehdr → vfg`, after scaling and tone mapping, before
dithering. Opt-in, one keybind, no rebuild.

| Piece | What |
| --- | --- |
| `shaders/crt-beam-sim.glsl` | the algorithm: per-pixel photon budget + rolling raster |
| `scripts/beam-sim.lua` | subframes/headroom choice, interpolation setup, live tuning, OSD |
| `input.conf` | `Ctrl+Alt+b` toggle + tuning binds |

Reference: <https://github.com/blurbusters/crt-beam-simulator> (`crt-simulator.glsl`,
MIT, Mark Rejhon / Timothy Lottes), <https://www.testufo.com/crt>,
<https://www.libretro.com/index.php/retroarch-first-program-to-support-blurbusters-crt-beam-racing-simulator-shader/>.
Independent implementation of the published algorithm, not a copy of the source.

## What the algorithm actually does

A sample-and-hold panel lights every pixel for the whole refresh period; that
persistence is the motion blur. A CRT lights each pixel for an instant as the
beam passes. The published algorithm does the same in software, but with a
twist that a plain black bar cannot do:

```text
light per sweep  = intensity * emission_time == linear_brightness * subframes
emission_time    = linear_brightness * subframes / intensity      (MPRT)
window           = one refresh of raster travel, at the beam position
output(per refresh) = intensity * overlap(emission interval, window)
```

Every pixel and colour channel gets its own emission interval, anchored where the
beam reaches it. Persistence (MPRT) is proportional to brightness, and the sweep
integral equals the source exactly, so **enabling the beam does not change the
picture's brightness** — that is the whole point of the intensity/duration split.

| pixel (linear) | emission (`beam_headroom=1`) | motion blur |
| --- | --- | --- |
| 1.00 (peak white) | the whole sweep | none — physics: a peak pixel cannot be brief |
| 0.32 (203 nits at a 630-nit peak) | 0.64 of a refresh | −36% |
| 0.16 (SDR white through TrueHDR) | 0.32 of a refresh | −68% |
| 0.05 | 0.10 of a refresh | −90% |

That is the "variable per-pixel MPRT" claim: bright highlights keep a longer
persistence, mid-tones and shadows get a very short one.

### The reference's GAIN_VS_BLUR is a brightness trade, and HDR cannot take it

The published shader defines `GAIN_VS_BLUR` as brightness: "0.5 is half
brightness spread over fewer frames", and the article therefore recommends
running the display in SDR. That is not usable in this chain — every pixel has to
keep the nits its metadata asks for, or PQ, the TrueHDR peak and the tone mapping
above it stop meaning anything. Its own HOWTO
(<https://github.com/blurbusters/crt-beam-simulator/issues/4>) states the rule
that actually matters: the simulator is Talbot-Plateau arithmetic, so the *time
average* over a sweep is what must be conserved.

So this port splits the two, and the split is why brightness survives:

- `beam_headroom` (PQ only, default `1.0`) — how far **above** `peak_nits` the
  beam may flash. `1.0` never exceeds the tone-mapped peak; `1.5` flashes at
  1.5x for 2/3 of the persistence; average nits unchanged either way. On an OLED
  with a 630-nit tone-map target and ~1000-nit small-window peak, `1.5` is the
  useful setting. SDR is pinned to `1.0`: 8-bit output cannot represent anything
  above its own white.
- `gain_vs_blur` (default `1.0`) — scales the intensity the beam is allowed to
  use. Above `1.0` it caps how much of `beam_headroom` is spent, so with
  `beam_headroom > 1` it lowers the peak flash load at unchanged average
  brightness. Below `1.0` it takes the intensity *under* the tone-mapped peak:
  pixels brighter than it emit at that level for the full sweep, so they dim and
  their persistence grows to the sweep length. The value is deliberately not
  clamped back up to `1.0`; that clamp made the knob a no-op whenever
  `beam_headroom` was at its default.

Persistence at headroom `H`: `MPRT = min(subframes, p * subframes / H)`
refreshes. The time average equals the source while `p <= H`; `H >= 1` keeps
that for every pixel, and `H < 1` (from `gain_vs_blur`) is the one deliberate
dimming mode.

## One deliberate deviation

The reference shader reads the three trailing frames so a pixel whose budget
exceeds one refresh keeps emitting in the *next* refreshes, showing the older
frame — the phosphor trail. mpv's user-shader API has no previous-frame texture,
so this port substitutes the current frame for those reads. Result: the budgets
tile the raster instead of overlapping, total light stays correct, MPRT still
scales with brightness, but a bright object has a longer persistence instead of
an aged ghost behind it.

## Why a user shader and not a CUDA `vf`

- `vf` runs *before* the VO: before scaling, before tone mapping. The budget is
  linear light, so masking earlier would make the mask a function of the tone
  curve — banding, and a different result per profile.
- The sweep needs the presented-frame index. libplacebo increments `frame` once
  per executed pass (`src/shaders/custom_mpv.c`), which is exactly one present.
  A filter has no idea when the VO presents or drops a frame.
- A `vf` sees the video rectangle, not the output geometry; and parameters set
  through `glsl-shader-opts` re-apply without recompiling, which a filter cannot
  do.

## Requirements

- **A new subframe every refresh.** The beam advances once per rendered frame, so
  the renderer must present one per refresh. VFG alone does *not* do that (it
  draws at its own `out-fps`), so the script always forces `interpolation=yes` +
  `video-sync=display-resample` + `tscale=oversample`, with or without VFG, and
  restores them on disable. Without it the mask only darkens the picture, and the
  OSD says so.
- **Linear light in, linear light out.** The budget is a photon count, so the
  shader needs the transfer function of what the `OUTPUT` hook actually receives.
  That is the **target**, not the chain: `transfer=pq` decodes and re-encodes
  with the real ST.2084 curve, `transfer=sdr` with a pure power curve.
  `detect_output()` therefore reads `video-out-params/gamma`:
  with `vo=gpu-next` + `target-colorspace-hint=yes` (the shipped `mpv.conf`) the
  target is PQ and the hook gets ST.2084 codes; with a tone-mapped SDR target the
  hook gets display codes and `transfer=pq` would decode them as PQ and darken
  the picture badly (measured: a 630-nit band collapsed from code 255 to 181).
  `peak_nits` is the target peak: `video-out-params/max-luma` when the compositor
  reports a real one (e.g. 654), else `target-peak`, else 1000 — a bare PQ target
  reports the 10000-nit encoding ceiling, which is not a display peak.
- **Fullscreen**, ideally direct scanout. Anything that makes the compositor skip
  or duplicate a present makes the beam stall or jump.

- **Display refresh must line up with what VFG emits**, with VRR off:
  `fps_out = display / k`, and the script retargets VFG there. At or below 0.8
  of the refresh `k` is an integer >= 2; above it the exact fractional ratio in
  `(1, 2)` is kept. That second case is the generator running fast: VFG x6 on
  23.976p emits 143.856 fps, so on a 165 Hz panel `k = 165/143.856 = 1.147` and
  every generated frame gets one sweep. `interpolation=yes` +
  `tscale=oversample` holds each frame `floor(k)` or `ceil(k)` refreshes either
  way, and the beam advances once per refresh. `k = 1` exactly is a fixed raster
  position (no beam), so it is never used; `MIN_SWEEP_HZ = 48`.

Subframes come from a **target sweep rate**, not from the container fps: the
renderer is fed `display/k` and nothing ties it to 24/30/60. Default target is
`TARGET_SWEEP_HZ = 72`; at or below 0.8 of the refresh the ratio is rounded to
an integer clamped to `2..32` and capped by `floor(display / MIN_SWEEP_HZ)`:

| display | 120 Hz | 144 Hz | 165 Hz | 240 Hz | 360 Hz |
| --- | --- | --- | --- | --- | --- |
| k | 2 | 2 | 2 | 3 | 5 |
| sweep | 60 Hz | 72 Hz | 82.5 Hz | 80 Hz | 72 Hz |
| VFG `out-fps` | 60 | 72 | 82.5 | 80 | 72 |

Above 0.8 of the refresh the rounding is dropped, so the generator can be asked
for a rate between half and all of the panel rate. That is `beam sweep 144` on
165 Hz, i.e. VFG x6 on 24p:

| display | request | k | sweep | VFG `out-fps` |
| --- | --- | --- | --- | --- |
| 165 Hz | `beam sweep 144` | 1.1458 | 144 Hz | 144.0 (x6 at 23.976p: 143.856) |

At `k` just above 1 the emission window covers most of the raster: the beam
still advances once per refresh, but what moves is a narrow **dark** arc (13%
of the frame at 1.147, backwards 12.8% of the screen per refresh -> a 21 Hz
cycle), not a lit band edge. Brightness is conserved because the sweep integral
is unchanged: over five phases at k = 1.147, mean nits were within 1.6% and the
per-pixel absolute deviation was 2.9% of the unmodulated picture, with no
clipping. Live at 143.85 fps: `frame-drop-count` stayed flat for 12 s, and a
bright frame showed a ~10% dark arc with row p-p 0.069.

**Two subframes are allowed.** An earlier version forced `k >= 3` on the theory
that two "cannot draw a rolling beam", but at 165 Hz that silently turned a
72 Hz target into a 55 Hz sweep whose three fixed raster positions the eye
reads as three bands. `k = 2` at 165 Hz is an 82.5 Hz sweep, two positions
above the panel's fusion limit, and it measured better. Fractional k *above* 2
(the reference's 2.75 at 165 Hz) does rotate the positions, but the pattern
repeats once per denominator sweeps (2.75 -> 15 Hz), which measured as flicker;
it is available through `beam subframes <n>` and `beam k`, and is not chosen
automatically. The sub-2 fractional case above is chosen automatically, because
rounding it has no correct integer answer.

### Modulation depth: `strength`

The beam's sweep integral already equals the source, so blending the beam output
toward the unmodulated picture keeps brightness and the time average exact and
scales only how deeply the scan modulates. That is `strength` (0 = plain
sample-and-hold, 1 = full rolling beam); the lua asks for **0.5 below ~220 Hz**
and 1.0 above, because at 165 Hz the band edge is a single fixed boundary that
some viewers latch onto as a line. The second full-depth case is a fast sub-two
sweep: when the sweep rate is at least 0.8 of the refresh (x6: 144 of 165 Hz),
the arc is narrow and moves most of the screen every refresh, so half depth only
halves the gain; `strength_for` returns 1.0 there. Measured on the 165 Hz panel
at k = 2, paused frame, row-profile peak-to-peak versus no shader: 34.1 code
values at 1.0, 12.6 at 0.5, 0.01 at 0.0. At k = 1.147 the same measure is 0.224
(normalized) at 1.0 and 0.055 at 0.5. `beam strength <0..1>` overrides it live.

### Two properties are forced while the beam is on

Both are saved before the change and restored by `beam off`:

- `vo=gpu-next`. The phase is driven by the shader's `frame` counter, and only
  gpu-next feeds it from libplacebo's per-hook-execution counter, which
  advances once per *presented refresh*. Legacy `vo=gpu` feeds it from
  `frames_uploaded`, which advances only when a new image arrives, so the beam
  would step once per generated frame instead of once per refresh (measured 58
  steps/s where 240 are needed) and the sweep would run at `refresh/k²`.
  Measured on the 165 Hz panel with the 8-band frame-counter probe shader:
  165.0 refreshes/s, 173.2 counter steps/s, the difference being exactly one
  extra hook run per `screenshot-to-file`.
- `hdr-compute-peak=no`. Peak detection is an extra pass over the image that
  runs the hook a second time (measured +8..18% counter steps at 240 Hz), so
  the beam skips phases and judders. The shader maps PQ per pixel and needs no
  global peak.

Integer frame multiplication cannot express 165/3 = 55, so the chain uses the
patched VFG filter's float-timestep mode (`FrameMultiplier=0` + `Timestep`,
filter option `out-fps`, runtime `vf-command vfg out-fps <fps>`). Measured on a
165 Hz panel: `est-vf=55`, **165.1 renders/s**, `subframes=3`, `transfer=pq`,
`peak_nits=630`; `beam off` restores VFG to its configured integer mode
(144 fps in that chain) and puts `interpolation`/`video-sync`/`tscale`,
`hdr-compute-peak` and `vo` back.

## Keybinds (60% layout, same convention as the DLSS 5 set)

| Key | Action |
| --- | --- |
| `Ctrl+Alt+b` | toggle the beam |
| `Ctrl+Alt+Shift+b` | cycle subframes 2 → 3 → 4 → 5 → 6 → 8 → 10 → 12 |
| `Ctrl+Alt+Shift+o` | subframes back to auto |
| `Ctrl+Alt+g` / `Ctrl+Alt+Shift+g` | headroom cap ±0.025 (never changes average brightness) |
| `Ctrl+Alt+a` | gain back to auto (`1.0`: brightest, sharpest) |
| `Ctrl+Alt+y` | raster: global (classic BFI) → top2bottom → bottom2top → left2right → right2left |
| `Ctrl+Alt+j` / `Ctrl+Alt+Shift+j` | raster phase shift ±0.05 sweep (moves the seam) |
| `Ctrl+Alt+l` | LCD anti-retention slew on/off (OLED does not need it) |
| `Ctrl+Alt+v` | status: subframes, gain, headroom, MPRT, sweep Hz |

Script messages: `script-message beam toggle|on|off|status`,
`beam subframes 4`, `beam gain 0.6`, `beam headroom 1.5`,
`beam direction top2bottom`, `beam raster -0.2`,
and the two that drive the pacing: `beam sweep 72` (target sweep rate in Hz; k is
re-derived and VFG is retargeted to `display/k`; `beam sweep 144` on 165 Hz gives
the fractional `k = 1.1458` above) and `beam k 3` (pin k directly, fractional
values like `beam k 1.147` included, which also retargets VFG). Both print the
resulting sweep, VFG rate and pacing verdict in the OSD, so it is obvious when a
refresh cannot be divided evenly.

To load it without a keybind, add `script=~~/scripts/beam-sim.lua` to `mpv.conf` (or place it in `~/.config/mpv/scripts/` to auto-load); to have it on
by default, `script-opts` are not needed — call `script-message beam on` from a
startup hook or press the bind.

## Verified

Measured on this box (RTX 5070, 165 Hz panel, driver 620.73.04), twice: on
`--gpu-api=opengl --gpu-context=wayland`, and on the shipped config
(`gpu-api=vulkan`, `gpu-context=waylandvk`) with the real `mpv.conf`. The two
backends agree within sampling noise; the numbers below are the Vulkan run.

Two instruments, in stages, each replaying/extracting the *shipped* source
(`/tmp/beam_check.py` extracts the PQ constants from the .glsl; the phase sweep
uses the real shader on the GPU):

```text
stage 1  SDR 8-bit ramp, k=2/4/8, H=1     sweep-average == source linear light   PASS
stage 2  PQ 10-bit, 0.5..630 nits, k=2/4  sweep-average nits == source nits     PASS
stage 3  headroom 1/1.5/2/4               average unchanged, flash == H*peak     PASS
stage 4  persistence                      MPRT == p*k/H, <= k for white          PASS
stage 5  no clipping at H=1               worst emitted sample 1.000 (k=2..8)     PASS
```

End-to-end on the GPU: a frozen screenshot cannot show a time integral, so the
integration walks the phase instead. `screenshot-to-file video` renders at a
fixed phase, but `raster_mod` shifts that phase deterministically, so 20
screenshots at `raster_mod = i/20` are the sweep integral (compared in linear
light, code 8-bit):

```text
band         beam off   beam on integral   deviation
near-white     236.0          235.7          0.27%
mid-grey       129.0          128.6          0.76%
near-black      15.0           15.3          4.8% (<1 code: 20-phase grid limit)
```

Before the fix the same measurement was 0.5x: `gain_vs_blur` was 0.5 on a 165 Hz
panel and the budget was `p * k * gain`, i.e. the reference's brightness trade.

Unit tests: `lua tests/beam-sim.lua` (and `luajit`). Each case was re-run against
five deliberate mutations (MPRT formula, gain tiers, HDR gamma, option merge,
state restore) and fails on all of them.

## Gotchas found the hard way

- A user shader may contain the two-character header marker **only** on real
  header lines. Prose that mentions it inline makes libplacebo abort the whole
  shader with `Unrecognized command`.
- `PARAM` blocks must come **before** the `HOOK` block: the hook parser consumes
  headers until the first non-header line and rejects `PARAM` inside that block.
- `~~/` paths only resolve when a config is loaded. `mpv --no-config` with
  `--glsl-shaders=~~/shaders/...` fails with `Failed to open shaders/...`.
- `frame-step` renders two frames per invocation, so step-based measurements read
  2 beam steps at a time. Not a shader bug, but it will mislead a test.
- The fork's `PREV` binding is not resolved at run time in the installed build:
  libplacebo logs `Skipping hook due to no texture named 'PREV'` and drops the
  whole pass, so a shader that binds it silently does nothing. The current
  shader therefore reuses `HOOKED` for the previous-sweep interval (only cost:
  the reference's bottom-edge correction on fast motion). Restore `PREV` when
  the bind path is fixed; verify with `--msg-level=vo/gpu-next=trace` that no
  `Skipping hook` line appears.

## Environment note

`--gpu-context=waylandvk` could not create a logical device
(`VK_ERROR_INITIALIZATION_FAILED`, libplacebo `context.c:1385`) on driver
620.73.04 before a reboot — with `--no-config` and with the real `mpv.conf`,
while `vulkaninfo` enumerated the GPU fine. After the reboot it initialises
normally and the shipped `gpu-api=vulkan` config runs the shader. If it comes
back, that is a driver/session problem, not this feature: the shader is
backend-agnostic and was verified on both.

## Limits worth repeating

- The sweep is driven by the renderer, not by the panel's scanout. Compositor
  effects, a non-fullscreen window, or a dropped present break the phase.
- Brightness is conserved, so persistence and brightness are no longer a trade.
  What *is* still constrained: a pixel at the display peak cannot be brief. For
  sharper highlights, raise `beam_headroom` (flash above the tone-map peak) or
  raise `truehdr:luminance` to what the panel can really do — both are real
  headroom, and neither changes average brightness.
- FALD/MiniLED backlights lag the panel and smear the beam; the reference advises
  against them for this algorithm.
- A 24 fps source at `subframes=8` really does flicker at 30 Hz per pixel. That
  is the technique, not a defect; if it bothers you, lower `subframes`.
