# CRT beam simulator (rolling scan) for the AI chain

Implements Blur Busters' CRT Beam Simulation on top of the finished chain: after
`hwup → dlssnr → vsr → truehdr → vfg`, after scaling and tone mapping, before
dithering. Opt-in, one keybind, no rebuild.

| Piece | What |
| --- | --- |
| `shaders/crt-beam-sim.glsl` | the algorithm: per-pixel photon budget + rolling raster |
| `scripts/beam-sim.lua` | subframes/gain choice, interpolation setup, live tuning, OSD |
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
budget(refresh units) = linear_brightness * subframes * gain_vs_blur
window                = one refresh of raster travel, at the current beam position
output(per refresh)   = length of the overlap between the budget interval and the window
```

Every pixel and colour channel gets its own emission interval, anchored where the
beam reaches it. Over one sweep the pixel delivers exactly
`linear_brightness * gain_vs_blur` of light, and persistence (MPRT) is
proportional to its brightness:

| pixel (linear) | MPRT at `gain_vs_blur=0.7` | motion blur |
| --- | --- | --- |
| 1.00 (white) | 0.70 of a frame | −30% |
| 0.22 (sRGB 0.5) | 0.15 of a frame | −85% |
| 0.05 | 0.04 of a frame | −96% |

That is the "variable per-pixel MPRT" claim: bright highlights keep a longer
persistence, mid-tones and shadows get a very short one. It is also why there is
no gain amplifier and no clipping to compensate for — per-refresh output is 1.0
at most by construction.

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
  shader needs the display's transfer function: `transfer=pq` decodes and
  re-encodes with the real ST.2084 curve (SMPTE points: 0.50 -> 92.25 nits,
  0.75 -> 983 nits) scaled by `peak_nits`, `transfer=sdr` uses a pure power
  curve. The AI chain forces `transfer=pq`: TrueHDR emits HDR10 even for SDR
  sources, so the script reads the *filter chain*, not `video-params/gamma`
  (which keeps reporting `bt.1886`), and takes `peak_nits` from the chain's
  `luminance`. Verified on the live chain: sweep-average out/in = 0.4998 for
  `gain_vs_blur=0.5`, max deviation 0.0003, no channel above 1.0.
- **Fullscreen**, ideally direct scanout. Anything that makes the compositor skip
  or duplicate a present makes the beam stall or jump.

- **Display refresh must be an integer multiple of what VFG emits**, with VRR
  off: `fps_out = display / k`, `k >= 2` integer, then `interpolation=yes` +
  `tscale=oversample` holds each generated frame for exactly `k` refreshes and
  the beam advances once per refresh. `k = 1` (sweep = refresh = 165 Hz) is a
  strobe, not a beam; `MIN_SWEEP_HZ = 48`.

Subframes come from a **target sweep rate**, not from the container fps: the
renderer is fed `display/k` and nothing ties it to 24/30/60. Default target is
`TARGET_SWEEP_HZ = 72`, so `k = round(display / 72)`, clamped to `2..32`:

| display | 96 Hz | 120 Hz | 144 Hz | 165 Hz | 240 Hz |
| --- | --- | --- | --- | --- | --- |
| k | 2 | 2 | 2 | 2 | 3 |
| sweep | 48 Hz | 60 Hz | 72 Hz | 82.5 Hz | 80 Hz |
| VFG `out-fps` | 48 | 60 | 72 | 82.5 | 80 |

Integer frame multiplication cannot express 165/2 = 82.5, so the chain uses the
patched VFG filter's float-timestep mode (`FrameMultiplier=0` + `Timestep`,
filter option `out-fps`, runtime `vf-command vfg out-fps <fps>`). Measured on a
165 Hz panel: `est-vf=82.5`, **165.1 renders/s**, `subframes=2`, `transfer=pq`,
`peak_nits=630`; `beam off` restores VFG to its configured integer mode
(144 fps in that chain) and puts `interpolation`/`video-sync`/`tscale` back.

## Keybinds (60% layout, same convention as the DLSS 5 set)

| Key | Action |
| --- | --- |
| `Ctrl+Alt+b` | toggle the beam |
| `Ctrl+Alt+Shift+b` | cycle subframes 2 → 3 → 4 → 5 → 6 → 8 → 10 → 12 |
| `Ctrl+Alt+Shift+o` | subframes back to auto |
| `Ctrl+Alt+g` / `Ctrl+Alt+Shift+g` | brightness-vs-clarity ±0.025 |
| `Ctrl+Alt+a` | gain back to the tier for the current refresh (0.7 at ≥200 Hz, 0.5 at ≥100 Hz, 0.35 below) |
| `Ctrl+Alt+y` | raster: global (classic BFI) → top2bottom → bottom2top → left2right → right2left |
| `Ctrl+Alt+j` / `Ctrl+Alt+Shift+j` | raster phase shift ±0.05 sweep (moves the seam) |
| `Ctrl+Alt+l` | LCD anti-retention slew on/off (OLED does not need it) |
| `Ctrl+Alt+v` | status: subframes, gain, MPRT, sweep Hz |

Script messages: `script-message beam toggle|on|off|status`,
`beam subframes 4`, `beam gain 0.6`, `beam direction top2bottom`, `beam raster -0.2`,
and the two that drive the pacing: `beam sweep 72` (target sweep rate in Hz; k is
re-derived and VFG is retargeted to `display/k`) and `beam k 3` (pin k directly,
which also retargets VFG). Both print the resulting sweep, VFG rate and pacing
verdict in the OSD, so it is obvious when a refresh cannot be divided evenly.

To load it without a keybind, add `script=beam-sim` to `mpv.conf`; to have it on
by default, `script-opts` are not needed — call `script-message beam on` from a
startup hook or press the bind.

## Verified

Measured on this box (RTX 5070, 165 Hz panel, driver 620.73.04), twice: on
`--gpu-api=opengl --gpu-context=wayland`, and on the shipped config
(`gpu-api=vulkan`, `gpu-context=waylandvk`) with the real `mpv.conf`. The two
backends agree within sampling noise; the numbers below are the Vulkan run.

The shader's light budget was first checked against a numpy reimplementation of
the published formula over a parameter grid (subframes 2–10, gain 0.3–1.0, all
raster phases, every brightness in 0..1): the per-refresh output never exceeded
1.0, and the sweep-average equalled `p * gain` exactly for every point.

Live playback of a ramp with the shipped config (`vulkan`/`waylandvk`,
`interpolation=yes`, `video-sync=display-resample`, `subframes=4`,
`gain_vs_blur=0.7`, 30 phase-random samples), by brightness:

```text
 x   p_lin   mean_lin/ref_lin   frames_lit   L= p*k*gain   ceil(L)/k
 48   0.030        0.746           0.267         0.09         0.25
168   0.281        0.746           0.267         0.79         0.25
192   0.364        0.743           0.500         1.02         0.50
288   0.829        0.706           0.767         2.32         0.75
```

- per-frame output ceiling: max 1.000 → nothing clips
- light conservation in linear light: `|ratio − 0.7|` mean 0.033 (OpenGL run:
  mean 0.033 too, max 0.050 there)
- frames lit per sweep tracks brightness (correlation 0.931, OpenGL run 0.851) at
  exactly `ceil(L)/k` → per-pixel MPRT is real, not a global duty cycle
- toggle through `script-binding beam_sim/beam-toggle` on the real config:
  shader appended to `glsl-shaders`, seven parameters registered,
  `interpolation`/`video-sync` switched on and restored on off

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
- Shorter persistence is dimmer light: `gain_vs_blur` is the trade, and the
  reference explicitly warns that HDR/peak boosts re-introduce banding.
- FALD/MiniLED backlights lag the panel and smear the beam; the reference advises
  against them for this algorithm.
- A 24 fps source at `subframes=8` really does flicker at 30 Hz per pixel. That
  is the technique, not a defect; if it bothers you, lower `subframes`.
