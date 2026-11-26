// CRT beam simulator -- mpv/libplacebo port of Blur Busters' CRT Beam Simulation
//
// Algorithm: Blur Busters CRT Beam Simulator / "rolling-scan CRT-BFI with per
// pixel variable MPRT", Mark Rejhon (@BlurBusters) + Timothy Lottes
// (@NOTimothyLottes), publicly released 2024.
//   https://github.com/blurbusters/crt-beam-simulator   (crt-simulator.glsl, MIT)
//   https://www.testufo.com/crt
//   https://www.libretro.com/index.php/retroarch-first-program-to-support-blurbusters-crt-beam-racing-simulator-shader/
// This file is an independent mpv-side implementation of that published
// algorithm, not a copy of the shader source.
//
// WHAT IT DOES (and what the first naive version got wrong)
//   A sample-and-hold panel shows every pixel for the whole refresh period,
//   which is what smears moving content. A CRT lights each pixel for a moment
//   as the beam passes. This shader reconstructs that by giving every pixel, in
//   every colour channel, a *photon budget* measured in refreshes:
//
//       L = linear_brightness * subframes * gain_vs_blur        (refreshes)
//
//   anchored at the moment the simulated beam reaches that pixel, and emits it
//   at the first opportunity. The pixel is lit while the current refresh window
//   overlaps its budget, and dark once the budget is spent, until the next
//   sweep. So MPRT (the persistence that causes motion blur) is proportional to
//   pixel brightness: bright highlights keep a long persistence, mid-tones and
//   shadows get a very short one. That is the "variable per-pixel MPRT" of the
//   published algorithm, and it is what avoids the two failure modes of a plain
//   rolling black bar: banding and clipping.
//
//   Light is conserved: over one sweep a pixel delivers exactly
//   linear_brightness * gain_vs_blur, so gain_vs_blur=1.0 is unchanged
//   brightness with no blur reduction on white, and 0.7 is the documented
//   recommendation for 240 Hz. Per-refresh output never exceeds 1.0 by
//   construction, so there is nothing to clip and nothing to "boost".
//
// DEVIATION FROM THE REFERENCE SHADER -- read this before judging the result
//   The published algorithm reads the three trailing frames on purpose: a pixel
//   whose budget exceeds one refresh keeps emitting in the *next* refreshes,
//   still showing the *older* frame, which is what gives the phosphor trail.
//   mpv's user-shader API has no previous-frame texture (no feedback target),
//   so this port substitutes the current frame for those trailing reads. The
//   budgets then tile the raster instead of overlapping, which keeps the total
//   light correct (verified: sum <= 1.0 for every brightness, sweep and gain)
//   and keeps MPRT proportional to brightness, but there is no aged ghost
//   behind bright pixels -- a bright object just has a longer persistence.
//
// WHERE IT RUNS
//   HOOK OUTPUT, i.e. after the whole filter chain (hwup/dlssnr/vsr/truehdr/vfg),
//   after scaling, after colour management and tone mapping, before dithering.
//   That ordering is required, not preferred: the photon budget is linear
//   light, so masking before the tone mapper would make the mask a function of
//   the tone curve. OSD and subtitles are drawn after hooks, so they stay
//   readable.
//
// THE SWEEP NEEDS SUBFRAMES
//   The beam advances once per *rendered* frame (libplacebo's `frame` counter),
//   so the renderer must produce a new subframe every refresh: interpolation=yes
//   with video-sync=display-resample, or the NVIDIA VFG filter presenting at the
//   display rate. scripts/beam-sim.lua sets that up and refuses to pretend.
//
// PARAMETERS are live (--glsl-shader-opts=crt-beam-sim/<name>=<v>); names follow
// the reference shader where it has one.
//   subframes       FRAMES_PER_HZ: native Hz / simulated CRT Hz. Reference uses
//                   4 for 60 fps on 240 Hz. Fractional values are allowed.
//   gain_vs_blur    GAIN_VS_BLUR: brightness-vs-clarity. 0.7 at 240 Hz, 0.5 at
//                   120 Hz (reference defaults).
//   gamma           display gamma for the linear-light budget: 2.2 for a
//                   standard sRGB SDR output, 2.4 recommended by the reference,
//                   1.0 to work on raw code values (PQ/HLG, approximate).
//   scan_direction  top2bottom (default) / bottom2top / global (classic BFI) /
//                   left2right / right2left. An ENUM parameter's default is the
//                   FIRST name in its list (libplacebo sets initial = index 0);
//                   a numeric default line is ignored, which is why the
//                   recommended mode is listed first and the dispatch below is
//                   numbered in that same order.
//   raster_mod      raster phase shift in sweeps, to move the beam seam.
//   anti_retention  LCD only: adds `slew` to even subframe counts so BFI cannot
//                   beat against the panel's voltage inversion. Not needed on
//                   OLED; see forums.blurbusters.com/viewtopic.php?t=7539.
//   slew            the anti-retention offset itself (reference: 0.001).
//
// Parser note: libplacebo splits a shader on the two-character header marker and
// aborts the whole file on an unknown command, so that marker may appear only on
// header lines, and all PARAM blocks must come before the HOOK block. Prose here
// never contains it.

//!PARAM subframes
//!DESC refreshes per simulated CRT sweep (native Hz / CRT Hz)
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 32.0
4.0
//!PARAM gain_vs_blur
//!DESC brightness vs clarity (1.0 = no blur reduction on white, 0.7 at 240 Hz)
//!TYPE float
//!MINIMUM 0.01
//!MAXIMUM 1.0
0.7
//!PARAM gamma
//!DESC display gamma for the linear-light photon budget (1.0 = raw code values)
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 2.6
2.2
//!PARAM scan_direction
//!DESC raster direction
//!TYPE ENUM int
top2bottom
bottom2top
global
left2right
right2left
//!PARAM raster_mod
//!DESC raster phase shift in sweeps (-1..1) to move the beam seam
//!TYPE float
//!MINIMUM -1.0
//!MAXIMUM 1.0
0.0
//!PARAM anti_retention
//!DESC LCD only: slew even subframe counts off the panel inversion frequency
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 1
0
//!PARAM slew
//!DESC anti-retention slew added to even subframe counts
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.02
0.001
//!PARAM transfer
//!DESC output transfer: 0 = sdr (power curve), 1 = pq (ST.2084, what TrueHDR emits)
//!TYPE ENUM int
sdr
pq
//!PARAM peak_nits
//!DESC PQ only: display peak the budget is normalised to (TrueHDR luminance)
//!TYPE float
//!MINIMUM 100.0
//!MAXIMUM 10000.0
700.0

//!HOOK OUTPUT
//!BIND HOOKED

// ST.2084 constants. TrueHDR emits PQ ("X2BGR10 HDR10 transfer=12") even for
// SDR sources and video-params/gamma keeps reporting the *source* curve, so the
// transfer must be an explicit parameter, not a guess from the source.
#define PQ_M1 (2610.0 / 16384.0)
#define PQ_M2 (2523.0 / 4096.0 * 128.0)
#define PQ_C1 (3424.0 / 4096.0)
#define PQ_C2 (2413.0 / 4096.0 * 32.0)
#define PQ_C3 (2392.0 / 4096.0 * 32.0)

// ST.2084 EOTF: PQ code value -> absolute nits.
float pq_to_nits(float e)
{
    float p = pow(max(e, 0.0), 1.0 / PQ_M2);
    return 10000.0 * pow(max(p - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * p, 1e-6),
                         1.0 / PQ_M1);
}

// ST.2084 inverse EOTF: nits -> PQ code value.
float pq_from_nits(float nits)
{
    float y = pow(max(nits, 0.0) / 10000.0, PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y), PQ_M2);
}

// Linear light for the budget, normalised so the display peak is 1.0.
//
// SDR uses a pure power curve, not the piecewise sRGB curve: sRGB's constants
// are only self-consistent at gamma = 2.4, so with the default gamma = 2.2 the
// joint was a step (0.00501 vs 0.00313 at c = 0.04045), and the inverse branch
// tested the already-encoded value instead of its input, moving the switch
// point and lighting deep shadows. A power curve is smooth, inverts exactly for
// any gamma, and is what the reference shader uses.
float bbs_decode(float c)
{
    if (transfer == 1)
        return clamp(pq_to_nits(c) / max(peak_nits, 1.0), 0.0, 1.0);
    c = max(c, 0.0);
    return (gamma <= 1.001) ? c : pow(c, gamma);
}

float bbs_encode(float c)
{
    if (transfer == 1)
        return pq_from_nits(max(c, 0.0) * max(peak_nits, 1.0));
    c = max(c, 0.0);
    return (gamma <= 1.001) ? c : pow(c, 1.0 / gamma);
}

vec4 hook()
{
    vec4 src = HOOKED_tex(HOOKED_pos);

    float k = clamp(subframes, 1.0, 32.0);
    // Reference: the effect is disabled below two refreshes per sweep.
    if (k < 2.0)
        return src;

    // LCD anti-retention: keep an even subframe count off the inversion pattern.
    float rk = floor(k + 0.5);
    bool is_int_k = abs(k - rk) < 1e-4;
    if (anti_retention == 1 && is_int_k && mod(rk, 2.0) == 0.0) {
        k += clamp(slew, 0.0, 0.02);
        is_int_k = false;
    }

    // Current position of the simulated beam, 0 = start of the sweep.
    // Use integer modulo when k is integral so long playback sessions do not
    // accumulate 24-bit float phase drift for non-power-of-two k (e.g. 3, 5).
    float phase = is_int_k ? (float(int(frame) % int(rk)) / rk)
                           : (mod(float(frame), k) / k);
    float raster = fract(phase + raster_mod);

    // The refresh window covers exactly one refresh of raster travel, which is
    // why one sweep takes `k` refreshes and only 1/k of the screen is lit.
    float f_start = raster * k;
    float f_end   = f_start + 1.0;

    // Where this pixel sits along the raster.
    // mpv/libplacebo HOOKED_pos has (0, 0) at top-left and (1, 1) at bottom-right.
    float tube_pos;
    if (scan_direction == 0)      tube_pos = HOOKED_pos.y;        // top to bottom
    else if (scan_direction == 1) tube_pos = 1.0 - HOOKED_pos.y;  // bottom to top
    else if (scan_direction == 2) tube_pos = 0.0;                 // global (BFI)
    else if (scan_direction == 3) tube_pos = HOOKED_pos.x;        // left to right
    else                          tube_pos = 1.0 - HOOKED_pos.x;  // right to left

    vec3 budget = vec3(bbs_decode(src.r), bbs_decode(src.g), bbs_decode(src.b));
    budget = clamp(budget * k * clamp(gain_vs_blur, 0.01, 1.0), vec3(0.0), vec3(k));

    float tube_frame = tube_pos * k;

    // Sum the overlap of this pixel's emission intervals with the current
    // window. Because f_start < k and k >= 2, f_end < k + 1 < 2*k, so only
    // copies at n in {-1, 0, 1} can overlap [f_start, f_end].
    vec3 lit = vec3(0.0);
    for (int n = -1; n <= 1; n++) {
        float start = tube_frame + float(n) * k;
        lit += clamp(min(start + budget, vec3(f_end)) - max(vec3(start), vec3(f_start)),
                     vec3(0.0), vec3(1.0));
    }

    // Per-refresh output is <= 1.0 by construction: no clipping, no gain boost.
    return vec4(bbs_encode(lit.r), bbs_encode(lit.g), bbs_encode(lit.b), src.a);
}
