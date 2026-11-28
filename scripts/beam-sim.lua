-- beam-sim.lua -- CRT beam simulator (Blur Busters CRT Beam Simulation) for mpv.
--
-- shaders/crt-beam-sim.glsl gives every pixel a photon budget in refreshes
-- proportional to its linear brightness, emitted when the simulated beam passes
-- it. Persistence (MPRT, the thing that smears moving content) therefore scales
-- with brightness instead of being one global black bar, which is what keeps the
-- image free of banding and clipping. See the header of the shader for the
-- algorithm and its one deviation from the published reference.
--
-- This script owns the parts the shader cannot decide for itself:
--   * subframes = refreshes per content frame (native Hz / simulated CRT Hz),
--     picked from the display refresh and the source frame rate;
--   * gain_vs_blur, the documented brightness-vs-clarity tradeoff for that
--     refresh rate (0.7 at 240 Hz, 0.5 at 120 Hz);
--   * interpolation, because the beam advances once per rendered frame: without
--     a new subframe per refresh the mask only darkens the picture;
--   * live tuning, via glsl-shader-opts, which re-applies parameters to the
--     parsed hook -- no shader recompile, no reload.
--
-- Honest limits, stated once here instead of on screen every time:
--   * the sweep is driven by the renderer's frame counter, not by the panel's
--     scanout. If the compositor does not present one rendered frame per
--     refresh (desktop effects, a scaled window, a dropped frame), the beam
--     stalls or skips. Fullscreen direct scanout is what makes it exact.
--   * HDR PQ sources and TrueHDR output use the ST.2084 EOTF/OETF path
--     (transfer=pq) normalised to peak_nits; HLG and SDR-tonemapped output
--     fall back to the SDR power curve.
--   * anti-retention is an LCD concern. OLED does not need it, and enabling it
--     decouples the sweep phase from the content, so it defaults to off here.

local SHADER_PATH  = "~~/shaders/crt-beam-sim.glsl"
local SHADER_NAME  = "crt-beam-sim"
local PARAMS       = { "subframes", "gain_vs_blur", "gamma", "scan_direction",
                       "raster_mod", "anti_retention", "slew", "transfer",
                       "peak_nits", "beam_headroom", "chroma_balance", "strength" }
local SUBFRAME_STEPS = { 2, 3, 4, 5, 6, 8, 10, 12 }
local DIRECTIONS  = { "global", "top2bottom", "bottom2top", "left2right", "right2left" }
local MAX_SUBFRAMES = 12
-- Sub-two sweeps are only meaningful when the generator runs faster than half
-- the refresh rate (VFG x6 at 165 Hz emits 143.86 fps -> k = 165/143.86 =
-- 1.147). k = 1 is a fixed raster position (a strobe, not a beam), so the floor
-- is just above one refresh; the shader uses the same bound.
local MIN_SUBFRAMES = 1.001
-- The sweep rate is display_hz / subframes, and it must never fall below this.
-- A 24 Hz beam is a strobe, not a CRT: 24p film was always projected through a
-- 48 or 72 Hz shutter for exactly this reason, and a rolling scan at 24 Hz is
-- worse than a black bar. So the rule is: one sweep per rendered frame
-- (subframes = display / render_rate), and if that lands below MIN_SWEEP_HZ the
-- render rate is what has to change (generate more frames), not the sweep.
local MIN_SWEEP_HZ = 48
-- Shader clamps subframes at 32; manual override is limited the same way.
local MAX_AUTO_SUBFRAMES = 32
-- sRGB 0.5 -> linear 0.216: the tone where smear is most visible.
local MID_LINEAR = 0.216

local state = {
    on             = false,
    subframes      = 4.0,
    subframes_auto = true,
    gain_vs_blur   = 1.0,
    gain_auto      = true,
    beam_headroom  = 1.0,
    chroma_balance = 1,
    strength       = 1.0,
    strength_auto  = true,
    gamma          = 2.2,
    scan_direction = "top2bottom",
    raster_mod     = 0.0,
    anti_retention = 0,
    slew           = 0.001,
    sweep_hz       = 72,
    transfer       = "sdr",
    peak_nits      = 700,
}

-- Saved player state, restored on disable.
local saved = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Beam intensity relative to the tone-mapped peak. Light conservation requires
-- intensity * emission_time == p * subframes, so a brighter beam means a shorter
-- flash for the same average nits. SDR cannot go above its own white, so
-- beam_headroom is ignored there; gain_vs_blur still scales the intensity and
-- may take it below 1.0, which dims pixels brighter than it (the shader's
-- peak-load trade). Mirrors the shader exactly -- no max(1.0) clamp, or a
-- gain < 1 would be dead while beam_headroom is at its default.
local function headroom_of(st)
    local h = clamp(st.gain_vs_blur or 1.0, 0.01, 1.0)
    if st.transfer == "pq" then
        h = h * clamp(st.beam_headroom or 1.0, 1.0, 8.0)
    end
    return h
end

-- Persistence, in refreshes, for a pixel of linear brightness p:
-- MPRT = p * subframes / headroom. At headroom 1.0 this is the conserving case
-- (a white pixel is held for a whole sweep, dimmer pixels are brief); more
-- headroom shortens every pixel's flash without touching the average.
local function mprt(st, linear_brightness, subframes)
    local p = clamp(linear_brightness, 0.0, 1.0)
    local k = subframes or st.subframes or 4.0
    return math.min(k, p * k / headroom_of(st))
end

-- Refreshes per rendered frame. `fps` here is the rate of the frames the
-- renderer actually draws (estimated-vf-fps: after VFG when it is active), not
-- the container rate -- the shader runs once per drawn frame, so one sweep per
-- drawn frame is what keeps the beam locked to the content.
--
-- Example with the float-timestep VFG: 24p, VFG out-fps = 165/2 = 82.5,
-- display 165 Hz -> subframes = 2, sweep = 82.5 Hz, one sweep per generated
-- frame, every refresh drawn once. No integer multiplier can do that.
-- Default sweep rate: what a good CRT ran at and what 24p film was projected
-- through (48/72 Hz shutters). The beam frequency is the knob, k is derived:
-- k = round(display Hz / sweep Hz), floored at 2 for the usual range; a target
-- above 0.8 of the refresh keeps the exact ratio in (1, 2) (see below).
--
-- Two subframes are allowed. An earlier version forced k >= 3 on the theory
-- that two "cannot draw a rolling beam", but at 165 Hz that silently turned a
-- 72 Hz request into a 55 Hz sweep, whose three beam positions the eye reads
-- as three fixed horizontal bands. k = 2 at 165 Hz is an 82.5 Hz sweep: two
-- beam positions above flicker fusion, measured better on the panel. The
-- reference also runs k = 2 on 120 Hz displays (FRAMES_PER_HZ = 2.0).
--
-- A requested sweep above 0.8 of the refresh rate is kept as an exact ratio
-- instead of being rounded: there the only integer k left is 1 (a fixed raster
-- position, i.e. no beam), and k = 2 would put the sweep below half the panel
-- rate. That is the frame-generator case (VFG x6 on 165 Hz emits 143.86 fps,
-- so k = 165/143.86 = 1.147, one sweep per generated frame). At k < 2 the beam
-- still advances once per refresh, but the emission window is most of the
-- raster, so the modulation is a narrow moving arc rather than a latched band
-- edge; the photon budget stays below 1 and brightness is conserved (measured
-- within 1.6% on 4K DoVi). Integer rounding here would turn `beam sweep 144`
-- on a 165 Hz panel into a 55 Hz or 82.5 Hz sweep, the banded cases above.
-- At or below 0.8 the integer rounding is kept: that is the reference's
-- two-refreshes-per-frame mode on 120/144/240 Hz panels (60/72/80 Hz sweeps).
--
-- Fractional k is chosen automatically only below 2. Above 2 it remains
-- manual-only: the reference's 2.75 at 165 Hz / 2.4 at 144 Hz rotates the beam
-- start and repeats the whole pattern once per denominator sweeps (2.75 ->
-- every 4 sweeps = 15 Hz), which measured as flickering bands.
local TARGET_SWEEP_HZ = 72

-- Refreshes per rendered frame, derived from the *wanted sweep rate* and not
-- from the source frame rate: with a generator in front the renderer is simply
-- told to produce display/k frames per second and every one of them gets one
-- sweep (VFG runs in float-timestep mode, which can hit a rate like 82.5 or
-- 143.856).
local function subframes_for(refresh, target_sweep)
    if type(refresh) ~= "number" or refresh < 20 then return 4.0 end
    target_sweep = tonumber(target_sweep) or TARGET_SWEEP_HZ
    if target_sweep < MIN_SWEEP_HZ then target_sweep = MIN_SWEEP_HZ end
    if target_sweep > 0.8 * refresh then
        return clamp(refresh / target_sweep, MIN_SUBFRAMES, 2.0)
    end
    local k_max = math.floor(refresh / MIN_SWEEP_HZ)
    local k = clamp(math.floor(refresh / target_sweep + 0.5), 2, MAX_AUTO_SUBFRAMES)
    if k > k_max and k_max >= 2 then k = k_max end
    return k + 0.0
end

-- Pacing verdict: the beam advances once per presented refresh (gpu-next), so
-- what has to line up is the generator rate with the sweep: VFG must emit
-- refresh/k frames per second, one sweep per generated frame. With integer k
-- that used to be an integer-ratio check; fractional k makes display/fps == k
-- itself the condition, so compare against k when it is known. Without k, fall
-- back to the integer-ratio check.
local function pacing_ok(refresh, fps, k)
    if type(refresh) ~= "number" or type(fps) ~= "number" then return false, "unknown" end
    if fps <= 0 then return false, "no-fps" end
    if fps < MIN_SWEEP_HZ then return false, "slow-sweep" end
    local ratio = refresh / fps
    if type(k) == "number" and k > 0 then
        if math.abs(ratio - k) > 0.02 * k then return false, "mismatch" end
        return true, "locked"
    end
    if math.abs(ratio - math.floor(ratio + 0.5)) > 0.01 then
        return false, "noninteger"
    end
    return true, "locked"
end

-- The reference's 0.7 (240 Hz) / 0.5 (120 Hz) numbers are brightness trades:
-- they dim the picture to shorten persistence. This chain keeps every pixel at
-- its metadata brightness, so there is nothing to trade away and the automatic
-- value is always 1.0 (use the full headroom). Lower it by hand only to reduce
-- peak flash load (OLED ABL), never for brightness.
local function gain_for(_)
    return 1.0
end

-- Modulation depth, i.e. how far the beam output may swing away from the plain
-- sample-and-hold picture. Full depth is the reference's effect, and it is only
-- honest where the sweep is far above flicker fusion: the reference's floor is
-- 240 Hz (FRAMES_PER_HZ 4 -> 60 Hz sweep, four raster positions, a 240 Hz
-- animation). At 165 Hz the fastest sweep is display/2 = 82.5 Hz with two
-- fixed raster positions, and a full-depth edge there is read as a latched
-- band rather than as clarity. Half depth keeps a real share of the clarity
-- gain while the band stays under that threshold; the user can override it with
-- `beam strength <0..1>`.
local FULL_STRENGTH_HZ = 220
local LOW_HZ_STRENGTH  = 0.5
-- A sub-two sweep is the second full-depth case: with k = 1.147 the raster
-- moves 87% of the screen every refresh, so the modulation is a narrow, fast
-- arc instead of a latched half-screen edge, and halving it only halves the
-- clarity gain. Keep the display-rate rule (the reference's 240 Hz floor) for
-- everything else; the sweep argument is optional so old callers still work.
local FAST_SWEEP_FRACTION = 0.8
local function strength_for(refresh, sweep)
    if type(refresh) ~= "number" then return LOW_HZ_STRENGTH end
    if refresh >= FULL_STRENGTH_HZ then return 1.0 end
    if type(sweep) == "number" and sweep >= FAST_SWEEP_FRACTION * refresh then
        return 1.0
    end
    return LOW_HZ_STRENGTH
end

local function fmt(v, digits)
    return string.format("%." .. tostring(digits) .. "f", v)
end

local function fmt_subframes(v)
    if math.abs(v - math.floor(v + 0.5)) < 1e-4 then
        return tostring(math.floor(v + 0.5))
    end
    return fmt(v, 4)
end

-- Parameter list for --glsl-shader-opts. Keys we do not own are preserved, so a
-- user tunable on the same shader keeps working across a toggle.
local function merge_opts(existing, st)
    local ours = {
        subframes      = fmt_subframes(st.subframes),
        gain_vs_blur   = fmt(st.gain_vs_blur, 3),
        gamma          = fmt(st.gamma, 3),
        scan_direction = st.scan_direction,
        raster_mod     = fmt(st.raster_mod, 4),
        anti_retention = tostring(math.floor(st.anti_retention + 0.5)),
        slew           = fmt(st.slew, 4),
        transfer       = (st.transfer == "pq") and "pq" or "sdr",
        peak_nits      = fmt(st.peak_nits or 700, 1),
        beam_headroom  = fmt(st.beam_headroom or 1.0, 2),
        chroma_balance = tostring(math.floor((st.chroma_balance or 1) + 0.5)),
        strength       = fmt(st.strength or 1.0, 3),
    }
    local out = {}
    local prefix = SHADER_NAME .. "/"
    if existing and existing ~= "" then
        for item in existing:gmatch("[^,]+") do
            local key = item:match("^([^=]+)=")
            -- Plain comparison, not a pattern: the shader name contains '-'.
            local name = nil
            if key and key:sub(1, #prefix) == prefix then
                name = key:sub(#prefix + 1)
            end
            if not (name and ours[name] ~= nil) then
                out[#out + 1] = item
            end
        end
    end
    for _, name in ipairs(PARAMS) do
        out[#out + 1] = prefix .. name .. "=" .. ours[name]
    end
    return table.concat(out, ",")
end

local function status_line(refresh, fps)
    local white = mprt(state, 1.0, state.subframes)
    local mid = mprt(state, MID_LINEAR, state.subframes)
    local sweep = (refresh and refresh > 0) and (refresh / math.max(state.subframes, 1)) or 0
    local ok, why = pacing_ok(refresh, fps, state.subframes)
    return string.format(
        "Beam %s | %s subframes%s | gain %.2f strength %.2f headroom %.2fx | MPRT white %.2f /"
        .. " mid %.2f of %s | sweep %.1f Hz | %g fps | %s | %s",
        state.on and "ON" or "OFF", fmt_subframes(state.subframes),
        state.subframes_auto and " auto" or "",
        state.gain_vs_blur, state.strength, headroom_of(state), white, mid,
        fmt_subframes(state.subframes), sweep, fps or 0,
        ok and "pacing locked" or ("pacing " .. tostring(why)),
        state.transfer == "pq" and ("PQ " .. tostring(state.peak_nits) .. "nits") or "SDR")
end

local function osd(text, secs)
    mp.osd_message(text, secs or 2.5)
end

local function refresh_hz()
    local hz = mp.get_property_number("display-fps", 0)
    if type(hz) ~= "number" or hz < 20 then return nil end
    return hz
end

local function source_fps()
    local fps = mp.get_property_number("container-fps", 0)
    if type(fps) ~= "number" or fps <= 0 then return nil end
    return fps
end

-- The OUTPUT hook runs *after* libplacebo's colour management, so what it
-- receives is the target space, not the chain's internal space. Two cases:
--   * HDR target (target-colorspace-hint with an HDR-capable compositor, or an
--     explicit --target-trc=pq): the hook gets ST.2084 codes that mean absolute
--     nits, so transfer=pq and peak_nits = the peak the display is driven at.
--   * SDR target: mpv tone-mapped everything (including whatever truehdr
--     produced upstream) to the target curve before the hook, so the codes are
--     display codes and transfer must be sdr.
-- Reading video-out-params is what tells these apart; the source's or the
-- chain's transfer cannot, which is why an earlier version mis-decoded a
-- tone-mapped frame as PQ and lost most of the brightness.
local function detect_output()
    local out_gamma = mp.get_property("video-out-params/gamma", "")
    if out_gamma == "pq" or out_gamma == "smpte2084" then
        -- max-luma is the peak the target/compositor reports, but a bare PQ
        -- target (no HDR compositor) reports the encoding ceiling 10000, which
        -- is not a display peak; anything that high falls through to target-peak.
        local peak = mp.get_property_number("video-out-params/max-luma", 0)
        if type(peak) ~= "number" or peak <= 0 or peak >= 9900 then
            peak = mp.get_property_number("target-peak", 0)
        end
        if type(peak) ~= "number" or peak <= 0 then peak = 1000 end
        return "pq", peak
    end
    -- SDR target: peak_nits is unused by the shader there (headroom is pinned
    -- to 1.0 as well), so report the reference white for the status line.
    return "sdr", 100
end

-- Frames the renderer actually draws per second: the VF chain output rate when
-- a filter changes it (VFG), otherwise the container rate. This is the rate the
-- shader's `frame` counter advances at, so it is the one subframes must divide.
local function render_fps()
    local fps = mp.get_property_number("estimated-vf-fps", 0)
    if type(fps) ~= "number" or fps <= 0 then return source_fps() end
    return fps
end

local function shader_present()
    local list = mp.get_property("glsl-shaders", "") or ""
    return list:find(SHADER_NAME, 1, true) ~= nil
end

local function apply_opts()
    mp.set_property("glsl-shader-opts",
        merge_opts(mp.get_property("glsl-shader-opts", "") or "", state))
end

-- Pick subframes, gain and gamma from the current display and source.
local function recompute()
    local refresh, fps = refresh_hz(), render_fps()
    if state.subframes_auto then
        state.subframes = subframes_for(refresh, state.sweep_hz)
    end
    if state.gain_auto then
        state.gain_vs_blur = gain_for(refresh)
    end
    if state.strength_auto then
        local sweep = (type(refresh) == "number" and refresh > 0)
                      and refresh / math.max(state.subframes, MIN_SUBFRAMES)
                      or nil
        state.strength = strength_for(refresh, sweep)
    end
    local transfer, peak = detect_output()
    state.transfer = transfer
    state.peak_nits = peak
    return refresh, fps
end

local function restore_property(name)
    local value = saved[name]
    if value ~= nil then
        mp.set_property(name, value)
    end
end

local function vfg_entry()
    local vf = (type(mp.get_property_native) == "function")
               and mp.get_property_native("vf", nil) or nil
    if type(vf) == "table" then
        for _, entry in ipairs(vf) do
            if entry.name == "vfg" and entry.enabled ~= false then return entry end
        end
        return nil
    end
    -- Fallback for the plain string property (and for the test harness).
    local chain = mp.get_property("vf", "") or ""
    for item in chain:gmatch("[^,]+") do
        if item:sub(1, 1) ~= "!" then
            local body = item:gsub("^@[^:]+:", "")
            if body == "vfg" or body:sub(1, 4) == "vfg:" or body:sub(1, 4) == "vfg=" then
                return { name = "vfg", chain = item }
            end
        end
    end
    return nil
end

-- Point VFG at exactly display/subframes fps (float timestep mode). Integer
-- multipliers cannot hit 165/2 = 82.5 or 165/1.147 = 143.856, so this is the
-- only way to get one beam sweep per generated frame on a 165 Hz panel.
local function retarget_vfg(refresh, k)
    if not vfg_entry() then return false end
    if type(refresh) ~= "number" or refresh < 20 or not k or k < MIN_SUBFRAMES then
        return false
    end
    local target = refresh / k
    mp.commandv("vf-command", "vfg", "out-fps", string.format("%.17g", target))
    return true
end

-- Push the current k everywhere it must agree: the shader's subframes, VFG's
-- output rate (display/k, float), and therefore the sweep rate (display/k) and
-- the pacing. Called after every change of k, of the refresh, or of the chain.
local function apply_targets()
    local refresh = refresh_hz()
    local k = state.subframes
    local retargeted = false
    if state.on then
        retargeted = retarget_vfg(refresh, k)
        apply_opts()
    end
    return refresh, retargeted
end

local function ensure_subframes_rendered()
    -- The beam advances once per *rendered* frame, so mpv must draw every
    -- refresh: VFG alone draws only at its own output rate (measured 96/s with
    -- VFG x4, or 38/s when the engine's shot-change fallback kept toggling),
    -- which cannot produce a 2-subframe sweep. Interpolation with
    -- tscale=oversample repeats the nearest frame without blending; each frame
    -- is then held floor(k) or ceil(k) refreshes (2 or 3 at k = 2.75), which is
    -- exactly the reference's non-integer FRAMES_PER_HZ.
    if mp.get_property("interpolation", "no") ~= "yes" then
        saved.interpolation = saved.interpolation or mp.get_property("interpolation", "no")
        mp.set_property("interpolation", "yes")
    end
    if mp.get_property("video-sync", "") ~= "display-resample" then
        saved["video-sync"] = saved["video-sync"] or mp.get_property("video-sync", "")
        mp.set_property("video-sync", "display-resample")
    end
    if mp.get_property("tscale", "") ~= "oversample" then
        saved.tscale = saved.tscale or mp.get_property("tscale", "")
        mp.set_property("tscale", "oversample")
    end
    -- The beam phase is driven by the shader's `frame` counter, and only
    -- vo=gpu-next increments it once per *presented refresh* (libplacebo's hook
    -- counter). vo=gpu feeds the counter from frames_uploaded, which advances
    -- only when a new image arrives, so the phase would step once per VFG frame
    -- and the sweep would run at refresh/k^2 -- measured 58 steps/s where 240
    -- were needed.
    local vo = mp.get_property("current-vo", "")
    local vo_opt = mp.get_property("vo", "")
    if vo ~= "" and vo ~= "gpu-next" and vo_opt ~= "" then
        saved.vo = saved.vo or vo_opt
        mp.set_property("vo", "gpu-next")
    end
    -- Peak detection is a second pass over the image that runs the hook again
    -- (measured +8..18% counter steps at 240 Hz), so the beam would skip phases
    -- and judder. The shader does its own PQ handling per pixel and needs no
    -- global peak, so this pass is pure artefact here.
    if mp.get_property("hdr-compute-peak", "auto") ~= "no" then
        saved["hdr-compute-peak"] = saved["hdr-compute-peak"]
            or mp.get_property("hdr-compute-peak", "auto")
        mp.set_property("hdr-compute-peak", "no")
    end
end

-- The rate VFG was configured with (0 = integer multiplier mode), read from the
-- native vf entry when available and otherwise from the string form
-- (`@vfg:vfg:out-fps=96`), which is what the tests and older mpv builds expose.
local function configured_vfg_out_fps()
    local entry = vfg_entry()
    if not entry then return "0" end
    local v = entry.params and entry.params["out-fps"]
    if v ~= nil then return tostring(v) end
    if type(entry.chain) == "string" then
        local m = entry.chain:match("out%-fps=([%d%.]+)")
        if m then return m end
    end
    return "0"
end

local function enable()
    if state.on then return end
    state.on = true

    saved["glsl-shader-opts"] = mp.get_property("glsl-shader-opts", "")
    -- The configured VFG rate has to come back when the beam goes off: after
    -- apply_targets() the filter runs in float-timestep mode at display/k, and
    -- leaving it there would keep a later beam-less playback at that rate.
    -- 0 means "no timestep target" (integer multiplier mode), which is what a
    -- chain that only sets fps/max-fps reports.
    if vfg_entry() and saved.vfg_out_fps == nil then
        saved.vfg_out_fps = configured_vfg_out_fps()
    end
    if not shader_present() then
        mp.commandv("change-list", "glsl-shaders", "append", SHADER_PATH)
    end
    ensure_subframes_rendered()

    local refresh, fps = recompute()
    -- apply_targets() may retarget VFG to display/k (float timestep). That
    -- command is asynchronous, so estimated-vf-fps still reports the previous
    -- multiplier here and the startup OSD showed a false "pacing mismatch".
    -- Report the rate the script just requested instead.
    local _, retargeted = apply_targets()
    if retargeted and refresh and state.subframes and state.subframes >= MIN_SUBFRAMES then
        fps = refresh / state.subframes
    end

    local text = status_line(refresh, fps)
    if not refresh then
        text = text .. "\nrefresh unknown: assuming 4 subframes"
    end
    if state.transfer == "pq" then
        text = text .. string.format("\nPQ output: linear-light budget, peak %g nits",
                                     state.peak_nits or 700)
    end
    osd(text, 3.5)
end

local function disable()
    if not state.on then return end
    state.on = false
    if shader_present() then
        mp.commandv("change-list", "glsl-shaders", "remove", SHADER_PATH)
    end
    restore_property("glsl-shader-opts")
    restore_property("interpolation")
    restore_property("video-sync")
    restore_property("tscale")
    restore_property("hdr-compute-peak")
    restore_property("vo")
    -- Only touch VFG if this script was the one that retargeted it.
    if saved.vfg_out_fps and vfg_entry() then
        mp.commandv("vf-command", "vfg", "out-fps", saved.vfg_out_fps)
    end
    saved = {}
    osd("Beam OFF", 1.5)
end

local function toggle()
    if state.on then disable() else enable() end
end

-- Live tuning. Every knob only rewrites glsl-shader-opts: libplacebo re-applies
-- the parameters to the already-parsed hook, so nothing is recompiled.
local function tuned(message, retarget)
    if state.on then
        if retarget then
            -- A sweep/subframe change moves the derived strength too (full
            -- depth above half the refresh rate, half below), so refresh the
            -- automatic values before re-pacing.
            recompute()
            apply_targets()
        else
            apply_opts()
        end
    end
    osd(message .. "\n" .. status_line(refresh_hz(), render_fps()), 2.5)
end

-- User-selectable sweep rate: the beam frequency is the primary knob, k is
-- derived from it (k = display / sweep). Both are exposed as commands.
local function set_sweep_hz(hz)
    local refresh = refresh_hz()
    if not refresh then return false end
    if hz < MIN_SWEEP_HZ then hz = MIN_SWEEP_HZ end
    local k = subframes_for(refresh, hz)
    state.sweep_hz = refresh / k
    state.subframes_auto = false
    state.subframes = k
    tuned(string.format("Beam sweep: %.1f Hz (k=%s of %.1f Hz)",
        refresh / k, fmt_subframes(k), refresh), true)
    return true
end

local function cycle_subframes()
    state.subframes_auto = false
    local next_k = SUBFRAME_STEPS[1]
    for _, k in ipairs(SUBFRAME_STEPS) do
        if k > state.subframes + 0.5 then
            next_k = k
            break
        end
    end
    state.subframes = clamp(next_k, 2, MAX_SUBFRAMES) + 0.0
    tuned("Beam subframes: " .. fmt_subframes(state.subframes), true)
end

local function toggle_subframes_auto()
    state.subframes_auto = not state.subframes_auto
    if state.subframes_auto then
        state.subframes = subframes_for(refresh_hz(), state.sweep_hz)
    end
    tuned("Beam subframes: " .. (state.subframes_auto and "auto" or "manual"), true)
end

local function adjust_gain(delta)
    state.gain_auto = false
    state.gain_vs_blur = clamp(state.gain_vs_blur + delta, 0.01, 1.0)
    tuned(string.format("Beam gain vs blur: %.3f", state.gain_vs_blur))
end

local function toggle_gain_auto()
    state.gain_auto = not state.gain_auto
    if state.gain_auto then
        state.gain_vs_blur = gain_for(refresh_hz())
    end
    tuned("Beam gain: " .. (state.gain_auto and "auto" or "manual"))
end

local function cycle_direction()
    for i, name in ipairs(DIRECTIONS) do
        if name == state.scan_direction then
            state.scan_direction = DIRECTIONS[(i % #DIRECTIONS) + 1]
            tuned("Beam sweep: " .. state.scan_direction)
            return
        end
    end
    state.scan_direction = DIRECTIONS[1]
    tuned("Beam sweep: " .. state.scan_direction)
end

local function toggle_anti_retention()
    state.anti_retention = (state.anti_retention == 0) and 1 or 0
    tuned("Beam anti-retention: " .. (state.anti_retention == 1 and "on (LCD)" or "off (OLED)"))
end

local function adjust_raster(delta)
    state.raster_mod = clamp(state.raster_mod + delta, -1.0, 1.0)
    tuned(string.format("Beam raster shift: %.2f sweep", state.raster_mod))
end

local function show_status()
    recompute()
    if state.on then apply_opts() end
    osd(status_line(refresh_hz(), render_fps()), 3.0)
end

-- Recompute on the events that change the answer. A profile switch rebuilds the
-- filter chain and can drop our shader from glsl-shaders, so re-append there.
local function on_video_change()
    if not state.on then return end
    if not shader_present() then
        mp.commandv("change-list", "glsl-shaders", "append", SHADER_PATH)
    end
    ensure_subframes_rendered()
    recompute()
    apply_targets()
end

mp.observe_property("video-params/gamma", "string", on_video_change)
-- The output target decides transfer/peak_nits (see detect_output): it is only
-- known once the VO is configured, and it changes when the compositor flips
-- between SDR and HDR.
mp.observe_property("video-out-params", "native", on_video_change)
mp.observe_property("display-fps", "number", on_video_change)
mp.register_event("file-loaded", on_video_change)
mp.register_event("video-reconfig", on_video_change)

mp.add_key_binding(nil, "beam-toggle", toggle)
mp.add_key_binding(nil, "beam-on", enable)
mp.add_key_binding(nil, "beam-off", disable)
mp.add_key_binding(nil, "beam-subframes-cycle", cycle_subframes)
mp.add_key_binding(nil, "beam-subframes-auto", toggle_subframes_auto)
mp.add_key_binding(nil, "beam-gain-up", function() adjust_gain(0.025) end)
mp.add_key_binding(nil, "beam-gain-down", function() adjust_gain(-0.025) end)
mp.add_key_binding(nil, "beam-gain-auto", toggle_gain_auto)
mp.add_key_binding(nil, "beam-direction-cycle", cycle_direction)
mp.add_key_binding(nil, "beam-raster-up", function() adjust_raster(0.05) end)
mp.add_key_binding(nil, "beam-raster-down", function() adjust_raster(-0.05) end)
mp.add_key_binding(nil, "beam-anti-retention-toggle", toggle_anti_retention)
mp.add_key_binding(nil, "beam-status", show_status)

mp.register_script_message("beam", function(cmd, arg1)
    cmd = (cmd or ""):lower()
    if cmd == "toggle" then
        toggle()
    elseif cmd == "on" then
        enable()
    elseif cmd == "off" then
        disable()
    elseif cmd == "sweep" then
        local hz = tonumber(arg1)
        if hz and hz > 0 then
            set_sweep_hz(hz)
        else
            osd("beam sweep: need Hz, e.g. script-message beam sweep 60", 3)
        end
    elseif cmd == "k" then
        local k = tonumber(arg1)
        if k then
            state.subframes_auto = false
            state.subframes = clamp(k, MIN_SUBFRAMES, MAX_AUTO_SUBFRAMES) + 0.0
            tuned("Beam subframes: " .. fmt_subframes(state.subframes), true)
        end
    elseif cmd == "subframes" then
        local k = tonumber(arg1)
        if k then
            state.subframes_auto = false
            state.subframes = clamp(k, MIN_SUBFRAMES, MAX_SUBFRAMES) + 0.0
            tuned("Beam subframes: " .. fmt_subframes(state.subframes), true)
        else
            cycle_subframes()
        end
    elseif cmd == "gain" or cmd == "gain_vs_blur" then
        local v = tonumber(arg1)
        if v then
            state.gain_auto = false
            state.gain_vs_blur = clamp(v, 0.01, 1.0)
            tuned(string.format("Beam gain vs blur: %.3f", state.gain_vs_blur))
        end
    elseif cmd == "chroma" or cmd == "chroma_balance" then
        local v = tonumber(arg1)
        if v ~= nil then
            state.chroma_balance = (v >= 0.5) and 1 or 0
            tuned("Beam chroma balance: " .. ((state.chroma_balance == 1)
                and "on (one window, no colour fringing)"
                or "off (per-channel windows, shortest MPRT)"))
        else
            state.chroma_balance = (state.chroma_balance == 1) and 0 or 1
            tuned("Beam chroma balance: " .. ((state.chroma_balance == 1) and "on" or "off"))
        end
    elseif cmd == "strength" then
        local v = tonumber(arg1)
        if v then
            state.strength = clamp(v, 0.0, 1.0)
            state.strength_auto = false
            tuned(string.format("Beam strength: %.2f (%.0f%% modulation)",
                state.strength, state.strength * 100))
        else
            state.strength_auto = true
            local refresh = refresh_hz()
            local sweep = refresh and refresh / math.max(state.subframes, MIN_SUBFRAMES) or nil
            state.strength = strength_for(refresh, sweep)
            tuned(string.format("Beam strength: %.2f (auto)", state.strength))
        end
    elseif cmd == "headroom" or cmd == "beam_headroom" then
        local v = tonumber(arg1)
        if v then
            state.beam_headroom = clamp(v, 1.0, 8.0)
            tuned(string.format("Beam headroom: %.2fx%s", state.beam_headroom,
                state.transfer == "pq" and "" or " (SDR ignores it)"))
        end
    elseif cmd == "direction" then
        local found = false
        for _, name in ipairs(DIRECTIONS) do
            if name == arg1 then found = true end
        end
        if found then
            state.scan_direction = arg1
            tuned("Beam sweep: " .. state.scan_direction)
        else
            cycle_direction()
        end
    elseif cmd == "raster" then
        local v = tonumber(arg1)
        if v then
            state.raster_mod = clamp(v, -1.0, 1.0)
            tuned(string.format("Beam raster shift: %.2f sweep", state.raster_mod))
        end
    elseif cmd == "slew" then
        -- The reference's band-fading trick (issue #4): add a small offset to
        -- an even integer subframe count so the phase boundary rolls across the
        -- screen instead of latching in one place. 0.001 is the retention
        -- default; 0.01-0.05 makes the band "much fainter". Enabling a slew
        -- turns anti-retention on, which is what the shader keys the offset on.
        local v = tonumber(arg1)
        if v then
            state.slew = clamp(v, 0.0, 0.02)
            state.anti_retention = (state.slew > 0) and 1 or 0
            tuned(string.format("Beam slew: %.3f sweep%s", state.slew,
                state.anti_retention == 1 and " (band rolls)" or ""), true)
        else
            osd("beam slew: need a value, e.g. script-message beam slew 0.02", 3)
        end
    elseif cmd == "status" or cmd == "info" then
        show_status()
    else
        osd("beam: toggle, on, off, k <n>, sweep <hz>, subframes <n>, gain <f>, strength <f>, direction <name>, raster <f>, slew <f>, status", 4)
    end
end)

-- Exposed for tests/beam-sim.lua; mpv ignores the return value.
return {
    state = state,
    mprt = mprt,
    headroom_of = headroom_of,
    subframes_for = subframes_for,
    pacing_ok = pacing_ok,
    render_fps = render_fps,
    detect_output = detect_output,
    retarget_vfg = retarget_vfg,
    set_sweep_hz = set_sweep_hz,
    apply_targets = apply_targets,
    gain_for = gain_for,
    strength_for = strength_for,
    merge_opts = merge_opts,
    status_line = status_line,
    enable = enable,
    disable = disable,
    toggle = toggle,
    recompute = recompute,
    on_video_change = on_video_change,
}
