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
//       L = intensity * emission_time                        (light per sweep)
//
//   anchored at the moment the simulated beam reaches that pixel, and emits it
//   at the first opportunity. The pixel is lit while the current refresh window
//   overlaps its emission window, and dark once it is spent, until the next
//   sweep. So MPRT (the persistence that causes motion blur) is proportional to
//   pixel brightness: bright highlights keep a long persistence, mid-tones and
//   shadows get a very short one. That is the "variable per-pixel MPRT" of the
//   published algorithm, and it is what avoids the two failure modes of a plain
//   rolling black bar: banding and clipping.
//
// BRIGHTNESS IS PRESERVED -- and blur reduction is kept
//   The reference defines GAIN_VS_BLUR as a brightness trade ("0.5 is half
//   brightness spread over fewer frames") and recommends SDR mode for that
//   reason. That cannot be shipped in an HDR chain: every displayed pixel has to
//   keep the nits its metadata asks for, or PQ, the TrueHDR peak and the tone
//   mapping above it stop meaning anything. Its own HOWTO (blurbusters/
//   crt-beam-simulator issue #4) states the governing rule: the simulator is
//   Talbot-Plateau arithmetic, so what must be conserved is the *time average*
//   over a sweep, not the instantaneous sample.
//
//   So the emission is split into an intensity and a duration instead of being
//   folded into one brightness scale:
//
//       intensity * emission_time == p * subframes    (p = source linear light)
//       emission_time = p * subframes / intensity
//
//   MPRT == emission_time, so asking for a *higher* intensity gives a shorter,
//   brighter flash for the same average nits: peak headroom buys sharpness
//   instead of costing brightness. beam_headroom = 1.0 never exceeds the tone
//   mapped peak (nothing can clip); raising it uses whatever the panel has above
//   peak_nits. Either way the sweep integral equals the source, so enabling the
//   beam does not change the picture's brightness -- only its persistence.
//
//   With TrueHDR at peak_nits=630 an SDR white (100-203 nits) is p = 0.16-0.32,
//   i.e. a 0.32-0.64 refresh emission window at k=2: most of the blur reduction
//   and full brightness, no headroom needed. True HDR highlights near the peak
//   keep a longer persistence -- that is physics, not a bug: a pixel cannot be
//   both fully bright and brief unless the panel can flash above that peak, and
//   that is exactly what beam_headroom expresses.
//
//   gain_vs_blur scales the intensity the beam is allowed to use. Above 1.0 it
//   caps how much of beam_headroom is spent, so with beam_headroom > 1 it lowers
//   the peak flash load. Below 1.0 it takes the intensity under the tone-mapped
//   peak: pixels brighter than it emit at that level for the full sweep, i.e.
//   they dim and their persistence grows toward the sweep length. That is the
//   knob's real trade -- peak load against brightness and sharpness -- and it is
//   deliberately not clamped back up to 1.0, which made it a no-op whenever
//   beam_headroom was at its default 1.0.
//
// SEAM, AND THE PREVIOUS-CYCLE CONTENT
//   The reference reads the three trailing frames on purpose: the wrapped copy
//   of a pixel's emission (the copy anchored one sweep earlier, which is the
//   part still glowing at the bottom of the screen while the beam restarts at
//   the top) has to carry the *older* frame, or the bottom of the retrace seam
//   shows content that has not been scanned yet -- a tear at the top and bottom
//   edges on moving content.
//   This fork's libplacebo exposes that content through a PREV binding, but in
//   the installed build the bind is not resolved at run time: libplacebo traces
//   "Skipping hook due to no texture named 'PREV'" and drops the whole pass,
//   which silently disabled the entire effect. So the previous interval below
//   reuses the current content instead: the screen is correct, the effect is
//   present, and the only loss is the reference's bottom-edge correction on
//   fast motion. Restore PREV here once the fork's bind path is fixed.
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
//   gain_vs_blur    GAIN_VS_BLUR: the reference's brightness-vs-clarity trade.
//                   Here it caps how much of beam_headroom is used, so lowering
//                   it lengthens the emission window instead of dimming the
//                   picture. 1.0 (default) = use the full headroom.
//   beam_headroom   PQ only: how far above peak_nits the beam may flash. 1.0
//                   never exceeds the tone-mapped peak; 1.5 flashes at up to
//                   1.5x for 2/3 of the persistence. SDR is pinned to 1.0.
//   chroma_balance  1 (default): one emission window per pixel, set by its
//                   brightest channel, with each channel emitting at its own
//                   intensity inside it -- hue is identical in every refresh, no
//                   chroma ghosting. 0: per-channel windows, which gives the
//                   bright channel the shortest persistence but separates the
//                   channels in time (temporal colour fringing).
//   strength        modulation depth, 0..1. 1.0 is the full rolling beam; 0.0
//                   is plain sample-and-hold. Blending toward the input keeps
//                   the time average (and therefore brightness) exact and only
//                   scales the scan depth, so it is the way to make a latched
//                   band faint without dimming the picture or moving the band.
//                   scripts/beam-sim.lua asks for 0.5 below ~220 Hz.
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
//!DESC brightness vs clarity; 1.0 preserves source nits (required for HDR)
//!TYPE float
//!MINIMUM 0.01
//!MAXIMUM 1.0
1.0
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
//!PARAM beam_headroom
//!DESC PQ only: how far above peak_nits the beam may flash (1.0 = never above)
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 8.0
1.0
//!PARAM chroma_balance
//!DESC 1 = one emission window for the pixel (no chroma ghosting), 0 = per channel
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 1
1
//!PARAM strength
//!DESC 0 = plain sample-and-hold, 1 = full beam modulation
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
1.0

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
    // The previous-cycle content (the reference's prev2) would come from the
    // fork's PREV binding. In the current build that bind is not resolved:
    // libplacebo traces "Skipping hook due to no texture named 'PREV'" and
    // drops the whole pass, so the shader silently did nothing. Until that is
    // fixed, all three emission intervals carry the current content; the cost
    // is the reference's bottom-edge tear on moving content, not the effect.
    vec4 src_prev = src;

    float k = clamp(subframes, 1.0, 32.0);
    // The reference disables the effect below two refreshes per sweep. Allowing
    // just above one is what makes it usable with the frame generator: VFG x6 on
    // a 165 Hz panel emits 143.86 fps, i.e. 165/143.86 = 1.147 refreshes per
    // generated frame, one sweep per frame. The budget stays conservative there
    // (the three overlap terms sum to at most H for p <= 1, so no clipping);
    // what changes is the visual form: above k = 1 the emission intervals are
    // long enough that bright pixels overlap the next window and are simply
    // modulated, while dark pixels keep a narrow moving dark arc. Measured at
    // k = 1.147 on 4K DoVi: the sweep integral is within 1.6% of the
    // unmodulated picture, and the arc is ~10% of the frame. k = 1 exactly is a
    // fixed raster position (a strobe, not a beam), so it stays disabled.
    if (k < 1.001)
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
    // int(frame) wraps at 2^31, so past that point fall back to float mod
    // instead of producing a negative phase.
    float frame_f = float(frame);
    float phase;
    if (is_int_k && frame_f < 2147483000.0)
        phase = float(int(frame) % int(rk)) / rk;
    else
        phase = mod(frame_f, k) / k;
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

    vec3 pc = vec3(bbs_decode(src.r), bbs_decode(src.g), bbs_decode(src.b));
    vec3 pp = vec3(bbs_decode(src_prev.r), bbs_decode(src_prev.g), bbs_decode(src_prev.b));

    // Beam intensity relative to peak_nits. Light is conserved exactly:
    //
    //     intensity * emission_time == p * k      (over one sweep)
    //
    // For a given intensity H the emission window is therefore
    //
    //     d = p * k / H        (refreshes)
    //
    // and MPRT == d, so a higher H means a shorter, brighter flash: same
    // average nits (Talbot-Plateau, i.e. the source metadata is preserved),
    // less persistence. H = 1.0 never asks the panel for more than the tone
    // mapped peak, so nothing can clip; H > 1 uses whatever headroom the panel
    // has above peak_nits and flashes proportionally harder. SDR has no
    // headroom above white, so beam_headroom is ignored there; gain_vs_blur
    // still applies and may take H below 1.0 (dimming pixels brighter than H,
    // see the parameter notes at the top). Do not clamp it back up to 1.0:
    // that made the control dead at the default beam_headroom = 1.0.
    float headroom = (transfer == 1) ? clamp(beam_headroom, 1.0, 8.0) : 1.0;
    headroom *= clamp(gain_vs_blur, 0.01, 1.0);

    // Colour-balanced (chroma_balance = 1, default): one emission window for the
    // whole pixel, driven by its brightest channel, with each channel emitting
    // at its own intensity inside that window. The ratios between the channels
    // are then identical in every refresh, so the hue is preserved exactly and
    // there is no chroma ghosting -- the artefact that makes the picture look
    // dulled/washed when each channel is given its own persistence (the
    // reference added "colour balanced variable MPRT" for the same reason).
    //
    // chroma_balance = 0: per-channel windows, i.e. maximum blur reduction for
    // the bright channel at the cost of temporal colour separation.
    //
    // The current and previous content each carry their own budget, so each
    // gets its own window and intensity. (The previous budget is what the
    // phosphor was excited with one sweep ago; its emission is the part still
    // visible at the retrace seam.)
    vec3 emit_c, inten_c, emit_p, inten_p;
    if (chroma_balance == 1) {
        float wc = clamp(max(max(pc.r, pc.g), pc.b) * k / headroom, 0.0, k);
        emit_c = vec3(wc);
        inten_c = (wc > 1e-6) ? clamp(pc * k / wc, vec3(0.0), vec3(headroom)) : vec3(0.0);

        float wp = clamp(max(max(pp.r, pp.g), pp.b) * k / headroom, 0.0, k);
        emit_p = vec3(wp);
        inten_p = (wp > 1e-6) ? clamp(pp * k / wp, vec3(0.0), vec3(headroom)) : vec3(0.0);
    } else {
        emit_c = clamp(pc * k / headroom, vec3(0.0), vec3(k));
        inten_c = vec3(headroom);
        emit_p = clamp(pp * k / headroom, vec3(0.0), vec3(k));
        inten_p = vec3(headroom);
    }

    float tube_frame = tube_pos * k;

    // Sum the overlap of the pixel's emission intervals with the current
    // window over three trailing sweeps, exactly as the reference does:
    //
    //   [t - k, t - k + emit]  previous sweep's pass over this pixel,
    //                          carrying the previous cycle's content (PREV)
    //   [t,     t + emit]      current sweep, current content
    //   [t + k, t + k + emit]  next sweep, current content
    //
    // The wrapped copy is why a window near the end of one sweep can light
    // the bottom of the screen while the next sweep has already started at
    // the top: that light is the afterglow of the previous scan, and it must
    // show the frame that scan wrote, not the frame now at the top.
    //
    // With integer k and no phase offset the +k copy only touches the window
    // at a single point, but fractional k (anti_retention slew, raster_mod)
    // makes it genuinely cover the top edge -- the reference's "fix seam for
    // top edge".
    vec3 lit = vec3(0.0);
    lit += clamp(min(vec3(tube_frame - k) + emit_p, vec3(f_end)) -
                 max(vec3(tube_frame - k), vec3(f_start)),
                 vec3(0.0), vec3(1.0)) * inten_p;
    lit += clamp(min(vec3(tube_frame) + emit_c, vec3(f_end)) -
                 max(vec3(tube_frame), vec3(f_start)),
                 vec3(0.0), vec3(1.0)) * inten_c;
    lit += clamp(min(vec3(tube_frame + k) + emit_c, vec3(f_end)) -
                 max(vec3(tube_frame + k), vec3(f_start)),
                 vec3(0.0), vec3(1.0)) * inten_c;

    // Different content cycles can overlap in the same refresh at the seam;
    // the panel cannot flash past the configured headroom.
    lit = min(lit, vec3(headroom));

    // Modulation depth. The sweep integral already equals the source, so
    // blending toward the unmodulated sample-and-hold picture changes neither
    // brightness nor the time average -- it scales only how deeply the scan
    // modulates, and with it both the clarity gain and the visibility of the
    // beam edge. On a 165 Hz panel (two raster positions, 82.5 Hz sweep) the
    // edge is above flicker fusion for the panel but not for every viewer, so
    // scripts/beam-sim.lua lowers this below ~220 Hz instead of pretending.
    lit = mix(pc, lit, clamp(strength, 0.0, 1.0));

    return vec4(bbs_encode(lit.r), bbs_encode(lit.g), bbs_encode(lit.b), src.a);
}
