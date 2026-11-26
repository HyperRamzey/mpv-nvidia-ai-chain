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
                       "peak_nits" }
local SUBFRAME_STEPS = { 2, 3, 4, 5, 6, 8, 10, 12 }
local DIRECTIONS  = { "global", "top2bottom", "bottom2top", "left2right", "right2left" }
local MAX_SUBFRAMES = 12
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
    gain_vs_blur   = 0.7,
    gain_auto      = true,
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

-- Persistence, in content frames, for a pixel of linear brightness p:
-- MPRT = p * gain_vs_blur, clipped at one frame. This is the property the
-- algorithm exists for -- it is not a global duty cycle.
local function mprt(st, linear_brightness)
    local g = clamp(st.gain_vs_blur, 0.01, 1.0)
    return math.min(1.0, clamp(linear_brightness, 0.0, 1.0) * g)
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
-- through (48/72 Hz shutters). The beam frequency is the knob, k is derived.
local TARGET_SWEEP_HZ = 72

-- Refreshes per rendered frame, derived from the *wanted sweep rate* and not
-- from the source frame rate: with a generator in front the renderer is simply
-- told to produce display/k frames per second and every one of them gets one
-- sweep. Example: 165 Hz display, 72 Hz target -> k = 2, VFG out-fps = 82.5,
-- sweep 82.5 Hz, one sweep per generated frame. No integer multiplier can
-- produce 82.5, which is why VFG runs in float-timestep mode.
local function subframes_for(refresh, target_sweep)
    if type(refresh) ~= "number" or refresh < 20 then return 4.0 end
    target_sweep = tonumber(target_sweep) or TARGET_SWEEP_HZ
    if target_sweep < MIN_SWEEP_HZ then target_sweep = MIN_SWEEP_HZ end
    return clamp(math.floor(refresh / target_sweep + 0.5), 2, MAX_AUTO_SUBFRAMES) + 0.0
end

-- Pacing verdict: one rendered frame per subframes refreshes exactly. A
-- non-integer ratio means some beam steps are held for one extra refresh, which
-- is visible as horizontal banding (measured: 96 fps on 165 Hz = 1.72
-- refreshes per frame, ~72% of steps duplicated).
local function pacing_ok(refresh, fps)
    if type(refresh) ~= "number" or type(fps) ~= "number" then return false, "unknown" end
    if fps <= 0 then return false, "no-fps" end
    local ratio = refresh / fps
    if math.abs(ratio - math.floor(ratio + 0.5)) > 0.01 then
        return false, "noninteger"
    end
    if fps < MIN_SWEEP_HZ then return false, "slow-sweep" end
    return true, "locked"
end

-- Documented recommendation: 0.7 at 240 Hz, 0.5 at 120 Hz.
local function gain_for(refresh)
    if type(refresh) ~= "number" or refresh < 20 then return 0.7 end
    if refresh >= 200 then return 0.7 end
    if refresh >= 100 then return 0.5 end
    return 0.35
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
    local white = mprt(state, 1.0)
    local mid = mprt(state, MID_LINEAR)
    local sweep = (refresh and refresh > 0) and (refresh / math.max(state.subframes, 1)) or 0
    local ok, why = pacing_ok(refresh, fps)
    return string.format(
        "Beam %s | %s subframes%s | gain %.2f | MPRT white %.2f / mid %.2f frame"
        .. " | sweep %.1f Hz | %g fps | %s | %s",
        state.on and "ON" or "OFF", fmt_subframes(state.subframes),
        state.subframes_auto and " auto" or "",
        state.gain_vs_blur, white, mid, sweep, fps or 0,
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

local function is_pq_source()
    local gamma = mp.get_property("video-params/gamma", "")
    return gamma == "pq"
end

-- Frames the renderer actually draws per second: the VF chain output rate when
-- a filter changes it (VFG), otherwise the container rate. This is the rate the
-- shader's `frame` counter advances at, so it is the one subframes must divide.
local function render_fps()
    local fps = mp.get_property_number("estimated-vf-fps", 0)
    if type(fps) ~= "number" or fps <= 0 then return source_fps() end
    return fps
end

local function is_truthy(v)
    if v == true or v == 1 then return true end
    if type(v) ~= "string" then return false end
    local s = v:lower()
    return s == "yes" or s == "1" or s == "true" or s == "on"
end

-- The shader cannot tell what the output stage did to the frame: TrueHDR emits
-- PQ (ST.2084) even for SDR sources and video-params/gamma keeps reporting the
-- *source* curve, so detection reads both the source transfer and the filter
-- chain. Native HDR passes through TrueHDR unchanged, so check it first.
local function detect_output()
    if mp.get_property("target-colorspace-hint", "") == "no" then
        return "sdr", 700
    end
    if is_pq_source() then
        local tp = mp.get_property_number("target-peak", 0)
        return "pq", (tp and tp > 0) and tp or 1000
    end
    local vf = (type(mp.get_property_native) == "function")
               and mp.get_property_native("vf", nil) or nil
    if type(vf) == "table" then
        for _, entry in ipairs(vf) do
            if entry.name == "truehdr" and entry.enabled ~= false then
                local params = entry.params or {}
                if is_truthy(params.enable) then
                    local lum = tonumber(params.luminance)
                    return "pq", (lum and lum > 0) and lum or 700
                end
            end
        end
    end
    return "sdr", 700
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
-- multipliers cannot hit 165/2 = 82.5, so this is the only way to get one beam
-- sweep per generated frame on a 165 Hz panel.
local function retarget_vfg(refresh, k)
    if not vfg_entry() then return false end
    if type(refresh) ~= "number" or refresh < 20 or not k or k < 2 then return false end
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
    if state.on then
        retarget_vfg(refresh, k)
        apply_opts()
    end
    return refresh
end

local function ensure_subframes_rendered()
    -- The beam advances once per *rendered* frame, so mpv must draw every
    -- refresh: VFG alone draws only at its own output rate (measured 96/s with
    -- VFG x4, or 38/s when the engine's shot-change fallback kept toggling),
    -- which cannot produce a 2-subframe sweep. Interpolation with
    -- tscale=oversample repeats the nearest frame without blending, and on an
    -- integer display/render ratio each frame is held exactly k refreshes.
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
    apply_targets()

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
    local k = clamp(math.floor(refresh / hz + 0.5), 2, MAX_AUTO_SUBFRAMES)
    state.sweep_hz = refresh / k
    state.subframes_auto = false
    state.subframes = k + 0.0
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
            state.subframes = clamp(math.floor(k + 0.5), 2, MAX_AUTO_SUBFRAMES) + 0.0
            tuned("Beam subframes: " .. fmt_subframes(state.subframes), true)
        end
    elseif cmd == "subframes" then
        local k = tonumber(arg1)
        if k then
            state.subframes_auto = false
            state.subframes = clamp(k, 2, MAX_SUBFRAMES) + 0.0
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
    elseif cmd == "status" or cmd == "info" then
        show_status()
    else
        osd("beam: toggle, on, off, k <n>, sweep <hz>, subframes <n>, gain <f>, direction <name>, raster <f>, status", 4)
    end
end)

-- Exposed for tests/beam-sim.lua; mpv ignores the return value.
return {
    state = state,
    mprt = mprt,
    subframes_for = subframes_for,
    pacing_ok = pacing_ok,
    render_fps = render_fps,
    detect_output = detect_output,
    retarget_vfg = retarget_vfg,
    set_sweep_hz = set_sweep_hz,
    apply_targets = apply_targets,
    gain_for = gain_for,
    merge_opts = merge_opts,
    status_line = status_line,
    enable = enable,
    disable = disable,
    toggle = toggle,
    recompute = recompute,
    on_video_change = on_video_change,
}
