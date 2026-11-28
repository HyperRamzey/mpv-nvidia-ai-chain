-- Unit tests for scripts/beam-sim.lua, run with plain lua/luajit:
--     lua tests/beam-sim.lua
-- The script is loaded against a fake `mp` table, the same way
-- tests/vfg-sync-refresh.lua drives scripts/vfg-sync.lua.

local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/tests/[^/]+$") or "."
local script = root .. "/scripts/beam-sim.lua"

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s",
        label, tostring(expected), tostring(actual)))
end

local function near(actual, expected, label, eps)
    eps = eps or 1e-6
    assert(type(actual) == "number" and math.abs(actual - expected) < eps,
        string.format("%s: expected %.6f, got %s", label, expected, tostring(actual)))
end

local function contains(haystack, needle, label)
    assert(type(haystack) == "string" and haystack:find(needle, 1, true),
        string.format("%s: %q does not contain %q", label, tostring(haystack), needle))
end

local function missing(haystack, needle, label)
    assert(type(haystack) == "string" and not haystack:find(needle, 1, true),
        string.format("%s: %q must not contain %q", label, tostring(haystack), needle))
end

-- ---------------------------------------------------------------------------
-- fake mp
-- ---------------------------------------------------------------------------
local function new_player(initial)
    local player = {
        props = {},
        calls = {},
        observed = {},
        events = {},
        bindings = {},
        messages = {},
        osd = nil,
    }
    for k, v in pairs(initial or {}) do player.props[k] = v end

    local mp = {}
    function mp.get_property(name, default)
        local v = player.props[name]
        if v == nil then return default end
        return v
    end
    function mp.get_property_number(name, default)
        local v = tonumber(player.props[name])
        if v == nil then return default end
        return v
    end
    function mp.get_property_native(name, default)
        if player.native and player.native[name] ~= nil then
            return player.native[name]
        end
        return default
    end
    function mp.set_property(name, value)
        player.props[name] = value
        player.calls[#player.calls + 1] = { "set", name, value }
    end
    function mp.commandv(...)
        local args = { ... }
        player.calls[#player.calls + 1] = args
        -- Model mpv's list semantics for `change-list glsl-shaders <op> <path>`
        -- so presence checks behave the way they do in a real player.
        if args[1] == "change-list" and args[2] == "glsl-shaders" then
            local op, path = args[3], args[4]
            local list = {}
            for item in (player.props["glsl-shaders"] or ""):gmatch("[^,]+") do
                if item ~= path then list[#list + 1] = item end
            end
            if op == "append" then list[#list + 1] = path end
            player.props["glsl-shaders"] = table.concat(list, ",")
        end
    end
    function mp.osd_message(text, secs)
        player.osd = text
        player.osd_secs = secs
    end
    function mp.observe_property(name, ...)
        -- (name, type, callback); varargs keep the type slot from being an
        -- unused declaration.
        local callback = select(2, ...)
        player.observed[name] = callback
    end
    function mp.register_event(name, callback)
        player.events[name] = callback
    end
    function mp.add_key_binding(...)
        -- (key, name, callback); the key slot is unused by these tests.
        local _, name, callback = ...
        player.bindings[name] = callback
    end
    function mp.register_script_message(name, callback)
        player.messages[name] = callback
    end

    _G.mp = mp
    player.api = dofile(script)

    function player.count(...)
        local wanted, n = { ... }, 0
        for _, call in ipairs(player.calls) do
            local match = #call >= #wanted
            for i = 1, #wanted do
                if call[i] ~= wanted[i] then match = false end
            end
            if match then n = n + 1 end
        end
        return n
    end

    return player
end

local function opts_of(player)
    return player.props["glsl-shader-opts"] or ""
end

local function last_out_fps(player)
    for i = #player.calls, 1, -1 do
        local c = player.calls[i]
        if c[1] == "vf-command" and c[2] == "vfg" and c[3] == "out-fps" then
            return tonumber(c[4])
        end
    end
end

local function sdr(refresh, fps, extra)
    local props = {
        ["display-fps"] = refresh,
        ["container-fps"] = fps,
        ["interpolation"] = "no",
        ["video-sync"] = "audio",
        ["video-params/gamma"] = "bt.1886",
        ["glsl-shaders"] = "",
        ["glsl-shader-opts"] = "",
        ["vf"] = "",
    }
    for k, v in pairs(extra or {}) do props[k] = v end
    return props
end

-- ---------------------------------------------------------------------------
-- the two numbers the algorithm is about
-- ---------------------------------------------------------------------------
do
    local api = new_player().api

    -- Light conservation: intensity * emission_time == p * k. With no headroom
    -- the emission IS the persistence, so MPRT = p * k refreshes and brightness
    -- is preserved at every level.
    near(api.mprt({ subframes = 4 }, 1.0, 4), 4.0, "mprt: white holds a whole sweep")
    near(api.mprt({ subframes = 4 }, 0.216, 4), 0.864, "mprt: mid grey is brief")
    near(api.mprt({ subframes = 4 }, 0.0, 4), 0.0, "mprt: black never lights")
    near(api.mprt({ subframes = 2 }, 0.5, 2), 1.0, "mprt: proportional to brightness")
    -- PQ headroom buys sharpness instead of costing brightness.
    near(api.mprt({ subframes = 4, transfer = "pq", beam_headroom = 2.0 }, 1.0, 4),
         2.0, "mprt: PQ headroom 2 halves persistence")
    near(api.mprt({ subframes = 4, transfer = "pq", beam_headroom = 2.0,
                    gain_vs_blur = 0.5 }, 1.0, 4), 4.0,
         "mprt: gain caps the usable headroom")
    near(api.mprt({ subframes = 4, transfer = "sdr", beam_headroom = 4.0 }, 1.0, 4),
         4.0, "mprt: SDR pins headroom to 1.0")
    -- gain_vs_blur must reach the shader unclamped: at the default
    -- beam_headroom = 1.0 the old max(headroom, 1.0) made it a no-op, so
    -- Ctrl+Alt+g changed the OSD and nothing else.
    near(api.headroom_of({ transfer = "sdr", gain_vs_blur = 0.5 }), 0.5,
         "headroom: SDR gain 0.5 is not clamped back to 1.0")
    near(api.headroom_of({ transfer = "pq", beam_headroom = 2.0,
                           gain_vs_blur = 0.5 }), 1.0,
         "headroom: PQ gain caps beam_headroom")
    near(api.headroom_of({ transfer = "pq", beam_headroom = 1.5 }), 1.5,
         "headroom: PQ default gain uses the configured headroom")

    -- k follows the wanted sweep rate (default 72 Hz), never the source rate:
    -- the frame generator upstream supplies whatever rate is asked for. A target
    -- at or below 0.8 of the refresh rounds to an integer (>= 2); a faster one
    -- keeps the exact ratio, which is the VFG x6 case: 165 / 143.856 = 1.147.
    -- Fractional k above 2 is manual-only (its rotating beam start repeats the
    -- pattern once per denominator sweeps: 2.75 -> 15 Hz).
    equal(api.subframes_for(240), 3, "subframes: 240 Hz -> 80 Hz sweep")
    equal(api.subframes_for(165), 2, "subframes: 165 Hz -> 82.5 Hz sweep")
    equal(api.subframes_for(144), 2, "subframes: 144 Hz -> 72 Hz sweep")
    equal(api.subframes_for(120), 2, "subframes: 120 Hz -> 60 Hz sweep")
    near(api.subframes_for(60), 1.001, "subframes: a 60 Hz panel runs one sweep per refresh",
         1e-9)
    near(api.subframes_for(165, 143.856), 165 / 143.856,
         "subframes: x6 143.856 fps on 165 Hz -> k = 1.147", 1e-9)
    near(api.subframes_for(120, 100), 1.2, "subframes: explicit fast target kept fractional", 1e-9)
    equal(api.subframes_for(240, 60), 4, "subframes: explicit 60 Hz target -> 4")
    equal(api.subframes_for(240, 48), 5, "subframes: explicit 48 Hz target -> 5")
    equal(api.subframes_for(240, 10), 5, "subframes: target clamped to the 48 Hz floor")
    near(api.subframes_for(240, 400), 1.001,
         "subframes: a target above the refresh caps at one sweep per refresh", 1e-9)
    equal(api.subframes_for(nil), 4, "subframes: unknown refresh falls back")
    -- the sweep rate that actually results, rounded to 0.1 Hz
    near(240 / api.subframes_for(240), 80.0, "subframes: 240 Hz sweep", 0.05)
    near(165 / api.subframes_for(165), 82.5, "subframes: 165 Hz sweep", 0.05)
    equal(api.pacing_ok(165, 82.5), true, "pacing: 82.5 fps on 165 Hz is locked 1:2")
    equal(api.pacing_ok(240, 80), true, "pacing: 80 fps on 240 Hz is locked 1:3")
    local _, why = api.pacing_ok(165, 96)
    equal(why, "noninteger", "pacing: 96 fps on 165 Hz is non-integer")
    local _, why_slow = api.pacing_ok(60, 30)
    equal(why_slow, "slow-sweep", "pacing: a 30 Hz beam is rejected as too slow")
    -- pacing with k: the generator rate must be display/k, integer or not.
    equal(api.pacing_ok(165, 82.5, 2), true, "pacing: 82.5 fps on 165 Hz locks k = 2")
    equal(api.pacing_ok(165, 60, 2.75), true, "pacing: 60 fps on 165 Hz locks k = 2.75")
    local _, why_mismatch = api.pacing_ok(165, 60, 2)
    equal(why_mismatch, "mismatch", "pacing: 60 fps does not lock k = 2")

    -- The reference's per-refresh tiers are brightness trades; this chain keeps
    -- metadata brightness, so the automatic value is always the full headroom.
    near(api.gain_for(240), 1.0, "gain: 240 Hz keeps full brightness")
    near(api.gain_for(165), 1.0, "gain: 165 Hz keeps full brightness")
    near(api.gain_for(120), 1.0, "gain: 120 Hz keeps full brightness")
    near(api.gain_for(nil), 1.0, "gain: unknown refresh keeps full brightness")

    -- Modulation depth: full only where the sweep is far above flicker fusion.
    near(api.strength_for(240), 1.0, "strength: 240 Hz runs full depth")
    near(api.strength_for(220), 1.0, "strength: 220 Hz is the floor for full depth")
    near(api.strength_for(165), 0.5, "strength: 165 Hz runs half depth")
    near(api.strength_for(120), 0.5, "strength: 120 Hz runs half depth")
    near(api.strength_for(nil), 0.5, "strength: unknown refresh runs half depth")
    -- A fast sub-two sweep is the second full-depth case: the arc is narrow and
    -- moves most of the screen every refresh, so halving it only halves the gain.
    near(api.strength_for(165, 143.856), 1.0, "strength: x6 sweep runs full depth")
    near(api.strength_for(165, 132), 1.0, "strength: 0.8 of the refresh is the floor")
    near(api.strength_for(165, 82.5), 0.5, "strength: k=2 at 165 Hz stays half depth")
end

-- ---------------------------------------------------------------------------
-- option string handling
-- ---------------------------------------------------------------------------
do
    local api = new_player().api
    local st = {
        subframes = 4.0, gain_vs_blur = 1.0, gamma = 2.2,
        scan_direction = "top2bottom", raster_mod = 0.0,
        anti_retention = 0, slew = 0.001,
    }

    local merged = api.merge_opts(
        "crt-beam-sim/gain_vs_blur=1.0,other-shader/x=2,crt-beam-sim/custom=7", st)
    contains(merged, "crt-beam-sim/subframes=4", "merge: subframes written")
    contains(merged, "crt-beam-sim/gain_vs_blur=1.000", "merge: ours replaced")
    contains(merged, "crt-beam-sim/scan_direction=top2bottom", "merge: enum written")
    contains(merged, "crt-beam-sim/anti_retention=0", "merge: int written")
    contains(merged, "other-shader/x=2", "merge: foreign shader kept")
    contains(merged, "crt-beam-sim/custom=7", "merge: unknown key of ours kept")
    missing(merged, "crt-beam-sim/gain_vs_blur=1.0,", "merge: stale value dropped")
    contains(merged, "crt-beam-sim/beam_headroom=1.00", "merge: beam headroom written")
    contains(merged, "crt-beam-sim/strength=1.000", "merge: strength written")
    missing(merged, ",,", "merge: no empty fields")

    st.subframes = 3.5
    contains(api.merge_opts("", st), "crt-beam-sim/subframes=3.5000",
        "merge: fractional subframes survive")
end

-- ---------------------------------------------------------------------------
-- enable / disable
-- ---------------------------------------------------------------------------
do
    local player = new_player(sdr(240, 24, { ["glsl-shader-opts"] = "nlmeans/strength=2" }))
    local api = player.api

    api.enable()
    equal(player.count("change-list", "glsl-shaders", "append", "~~/shaders/crt-beam-sim.glsl"), 1,
        "enable: shader appended once")
    equal(player.props["interpolation"], "yes", "enable: interpolation on")
    equal(player.props["video-sync"], "display-resample", "enable: display sync on")
    equal(api.state.subframes, 3, "enable: 3 subframes for an 80 Hz sweep on 240 Hz")
    near(api.state.gain_vs_blur, 1.0, "enable: gain 1.0 (brightness is not traded)")
    contains(opts_of(player), "crt-beam-sim/subframes=3", "enable: subframes pushed")
    contains(opts_of(player), "crt-beam-sim/gain_vs_blur=1.000", "enable: gain pushed")
    contains(opts_of(player), "crt-beam-sim/gamma=2.200", "enable: SDR gamma pushed")
    contains(opts_of(player), "crt-beam-sim/transfer=sdr", "enable: SDR transfer pushed")
    contains(opts_of(player), "crt-beam-sim/peak_nits=", "enable: peak nits pushed")
    contains(opts_of(player), "crt-beam-sim/strength=1.000", "enable: full depth on 240 Hz")
    contains(opts_of(player), "nlmeans/strength=2", "enable: foreign option kept")
    contains(player.osd, "Beam ON", "enable: OSD announces")
    contains(player.osd, "MPRT", "enable: OSD reports persistence")

    api.enable()
    equal(player.count("change-list", "glsl-shaders", "append", "~~/shaders/crt-beam-sim.glsl"), 1,
        "enable: a second toggle does not append again")

    api.disable()
    equal(player.count("change-list", "glsl-shaders", "remove", "~~/shaders/crt-beam-sim.glsl"), 1,
        "disable: shader removed")
    equal(player.props["interpolation"], "no", "disable: interpolation restored")
    equal(player.props["video-sync"], "audio", "disable: video-sync restored")
    equal(player.props["glsl-shader-opts"], "nlmeans/strength=2", "disable: options restored")
end

do
    -- 165 Hz: two raster positions, 82.5 Hz sweep. The band edge is above the
    -- panel's fusion but not always above the viewer's, so the automatic depth
    -- is halved instead of pretending full-depth is artefact-free there.
    local player = new_player(sdr(165, 24))
    player.api.enable()
    near(player.api.state.strength, 0.5, "enable: half depth on 165 Hz")
    contains(opts_of(player), "crt-beam-sim/strength=0.500", "enable: half depth pushed")
    contains(player.osd, "strength 0.50", "enable: OSD shows the depth")
end

do
    -- VFG present: interpolation is still forced (the beam advances once per
    -- *rendered* frame, and VFG alone renders only at its own rate), and VFG is
    -- retargeted to display/k in float-timestep mode.
    local player = new_player(sdr(120, 60, { ["vf"] = "@hwup:hwup,@vfg:vfg:fps=auto:max-fps=120" }))
    local api = player.api
    api.enable()
    equal(player.props["interpolation"], "yes", "vfg: interpolation forced on")
    equal(player.props["video-sync"], "display-resample", "vfg: display sync forced on")
    equal(player.props["tscale"], "oversample", "vfg: oversample forced on")
    equal(api.state.subframes, 2, "vfg: 120 Hz -> 60 Hz sweep, k=2")
    equal(player.count("vf-command", "vfg", "out-fps", "60"), 1,
        "vfg: retargeted to display/k via float timestep")
    api.disable()
    equal(player.count("vf-command", "vfg", "out-fps", "0"), 1,
        "vfg: disable restores integer multiplier mode (out-fps 0)")
end

do
    -- A chain that already runs float timestep mode: the beam must put that
    -- configured rate back instead of forcing 0, which would silently change how
    -- the chain behaves once the beam is switched off.
    local player = new_player(sdr(240, 24, {
        ["vf"] = "@hwup:hwup,@vfg:vfg:out-fps=96:mode=high",
    }))
    local api = player.api
    api.enable()
    equal(api.state.subframes, 3, "vfg-configured: 240 Hz -> 80 Hz sweep, k=3")
    equal(player.count("vf-command", "vfg", "out-fps", "80"), 1,
        "vfg-configured: retargeted to display/k = 80")
    api.disable()
    equal(player.count("vf-command", "vfg", "out-fps", "96"), 1,
        "vfg-configured: disable restores the configured 96 fps")
end

do
    -- HDR *target*: the OUTPUT hook receives ST.2084 codes (mpv passes PQ
    -- through when the output is HDR), so the budget runs on absolute nits.
    local player = new_player(sdr(240, 24, {
        ["video-out-params/gamma"] = "pq",
        ["video-out-params/max-luma"] = 654,
        ["interpolation"] = "yes",
        ["video-sync"] = "display-resample",
    }))
    local api = player.api
    api.enable()
    contains(opts_of(player), "crt-beam-sim/transfer=pq", "hdr: PQ transfer selected")
    contains(opts_of(player), "crt-beam-sim/peak_nits=654.0", "hdr: peak nits from max-luma")
    contains(opts_of(player), "crt-beam-sim/gain_vs_blur=1.000", "hdr: gain is 1.0 (brightness kept)")
    contains(player.osd, "PQ output", "hdr: OSD reports the PQ budget")

    -- Compositor flips to SDR: the hook now gets tone-mapped display codes, so
    -- decoding them as PQ would darken the picture badly (measured: 255 -> 181).
    player.props["video-out-params/gamma"] = "bt.1886"
    player.observed["video-out-params"]("video-out-params", {})
    contains(opts_of(player), "crt-beam-sim/transfer=sdr", "hdr->sdr: transfer follows the target")
    contains(opts_of(player), "crt-beam-sim/gamma=2.200", "hdr->sdr: linear-light budget back")
end

-- ---------------------------------------------------------------------------
-- live tuning (opts only, never a shader reload)
-- ---------------------------------------------------------------------------
do
    local player = new_player(sdr(240, 60, {
        ["interpolation"] = "yes",
        ["video-sync"] = "display-resample",
    }))
    local api = player.api
    api.enable()
    equal(api.state.subframes, 3, "tuning: 240 Hz starts at 3 (80 Hz sweep)")

    player.bindings["beam-subframes-cycle"]()
    equal(api.state.subframes, 4, "tuning: cycle steps 3 -> 4")
    contains(opts_of(player), "crt-beam-sim/subframes=4", "tuning: cycle pushes opts")
    for _, want in ipairs({ 5, 6, 8, 10, 12 }) do
        player.bindings["beam-subframes-cycle"]()
        equal(api.state.subframes, want, "tuning: cycle reaches " .. want)
    end
    player.bindings["beam-subframes-cycle"]()
    equal(api.state.subframes, 2, "tuning: cycle wraps back to 2")

    local appends = player.count("change-list", "glsl-shaders", "append",
        "~~/shaders/crt-beam-sim.glsl")
    player.bindings["beam-gain-down"]()
    equal(api.state.gain_auto, false, "tuning: manual gain disables auto")
    near(api.state.gain_vs_blur, 0.975, "tuning: gain steps down by 0.025")
    contains(opts_of(player), "crt-beam-sim/gain_vs_blur=0.975", "tuning: gain pushed")
    equal(player.count("change-list", "glsl-shaders", "append",
        "~~/shaders/crt-beam-sim.glsl"), appends, "tuning: no shader reload for a parameter")

    for _ = 1, 60 do player.bindings["beam-gain-up"]() end
    near(api.state.gain_vs_blur, 1.0, "tuning: gain clamps at 1.0 (full headroom)")
    for _ = 1, 60 do player.bindings["beam-gain-down"]() end
    near(api.state.gain_vs_blur, 0.01, "tuning: gain clamps at 0.01")

    -- beam_headroom is the knob that buys sharpness without touching brightness
    equal(api.state.beam_headroom, 1.0, "headroom: defaults to 1.0 (never above peak)")
    player.messages["beam"]("headroom", "2.5")
    near(api.state.beam_headroom, 2.5, "headroom: set from a message")
    contains(opts_of(player), "crt-beam-sim/beam_headroom=2.50", "headroom: pushed")
    player.messages["beam"]("headroom", "99")
    near(api.state.beam_headroom, 8.0, "headroom: clamped at 8x")
    player.messages["beam"]("headroom", "0.1")
    near(api.state.beam_headroom, 1.0, "headroom: clamped at 1.0x")

    -- Colour balance: one emission window per pixel (default) so the channels
    -- keep their ratios in every refresh; off gives per-channel persistence.
    equal(api.state.chroma_balance, 1, "chroma: balanced by default")
    contains(opts_of(player), "crt-beam-sim/chroma_balance=1", "chroma: pushed")
    player.messages["beam"]("chroma", "0")
    equal(api.state.chroma_balance, 0, "chroma: message turns it off")
    contains(opts_of(player), "crt-beam-sim/chroma_balance=0", "chroma: off pushed")
    player.messages["beam"]("chroma")
    equal(api.state.chroma_balance, 1, "chroma: bare message toggles back")

    -- Modulation depth: the knob that makes a latched band faint without
    -- moving it and without changing brightness (the time average is exact).
    equal(api.state.strength, 1.0, "strength: full depth by default on 240 Hz")
    player.messages["beam"]("strength", "0.3")
    near(api.state.strength, 0.3, "strength: set from a message")
    equal(api.state.strength_auto, false, "strength: manual disables auto")
    contains(opts_of(player), "crt-beam-sim/strength=0.300", "strength: pushed")
    player.messages["beam"]("strength", "9")
    near(api.state.strength, 1.0, "strength: clamps at 1.0")
    player.messages["beam"]("strength", "-1")
    near(api.state.strength, 0.0, "strength: clamps at 0.0")
    player.messages["beam"]("strength")
    equal(api.state.strength_auto, true, "strength: bare message returns to auto")
    near(api.state.strength, 1.0, "strength: auto is full depth on 240 Hz")

    player.bindings["beam-gain-auto"]()
    equal(api.state.gain_auto, true, "tuning: auto gain back on")
    near(api.state.gain_vs_blur, 1.0, "tuning: auto gain is 1.0 (brightness kept)")

    player.bindings["beam-subframes-auto"]()
    equal(api.state.subframes_auto, true, "tuning: auto subframes back on")
    equal(api.state.subframes, 3, "tuning: auto subframes recomputed from target sweep (72 Hz)")

    player.bindings["beam-direction-cycle"]()
    equal(api.state.scan_direction, "bottom2top", "tuning: direction advances")
    contains(opts_of(player), "crt-beam-sim/scan_direction=bottom2top", "tuning: direction pushed")
    for _ = 1, 4 do player.bindings["beam-direction-cycle"]() end
    equal(api.state.scan_direction, "top2bottom", "tuning: direction wraps through all five")

    player.bindings["beam-anti-retention-toggle"]()
    equal(api.state.anti_retention, 1, "tuning: anti-retention on")
    contains(opts_of(player), "crt-beam-sim/anti_retention=1", "tuning: anti-retention pushed")
    player.bindings["beam-anti-retention-toggle"]()
    equal(api.state.anti_retention, 0, "tuning: anti-retention off")

    player.bindings["beam-raster-up"]()
    near(api.state.raster_mod, 0.05, "tuning: raster shift")
    for _ = 1, 40 do player.bindings["beam-raster-up"]() end
    near(api.state.raster_mod, 1.0, "tuning: raster shift clamps")

    player.messages["beam"]("subframes", "8")
    equal(api.state.subframes, 8, "message: subframes set")
    equal(api.state.subframes_auto, false, "message: manual subframes")
    player.messages["beam"]("gain", "0.5")
    near(api.state.gain_vs_blur, 0.5, "message: gain set")
    player.messages["beam"]("direction", "left2right")
    equal(api.state.scan_direction, "left2right", "message: direction set")
    player.messages["beam"]("direction", "sideways")
    equal(api.state.scan_direction, "right2left", "message: unknown direction cycles")
    player.messages["beam"]("raster", "-0.5")
    near(api.state.raster_mod, -0.5, "message: raster set")

    -- The reference's band-fading offset: a slew on an even subframe count
    -- rolls the phase boundary instead of latching it.
    player.messages["beam"]("slew", "0.02")
    near(api.state.slew, 0.02, "message: slew set")
    equal(api.state.anti_retention, 1, "message: slew enables anti-retention")
    contains(opts_of(player), "crt-beam-sim/slew=0.0200", "message: slew pushed")
    contains(opts_of(player), "crt-beam-sim/anti_retention=1", "message: anti-retention pushed")
    player.messages["beam"]("slew", "9")
    near(api.state.slew, 0.02, "message: slew clamps at 0.02")

    player.bindings["beam-status"]()
    contains(player.osd, "subframes", "status: reports subframes")
    contains(player.osd, "MPRT", "status: reports persistence")
end

-- ---------------------------------------------------------------------------
-- re-append after a profile rebuild
-- ---------------------------------------------------------------------------
do
    local player = new_player(sdr(240, 24, {
        ["interpolation"] = "yes",
        ["video-sync"] = "display-resample",
    }))
    player.api.enable()
    player.props["glsl-shaders"] = "~~/CfL_Prediction.glsl"   -- profile dropped ours
    player.events["video-reconfig"]()
    equal(player.count("change-list", "glsl-shaders", "append", "~~/shaders/crt-beam-sim.glsl"), 2,
        "reconfig: shader re-appended")
    contains(opts_of(player), "crt-beam-sim/subframes=3", "reconfig: opts re-applied")

    player.props["glsl-shaders"] = "~~/CfL_Prediction.glsl,~~/shaders/crt-beam-sim.glsl"
    player.events["file-loaded"]()
    equal(player.count("change-list", "glsl-shaders", "append", "~~/shaders/crt-beam-sim.glsl"), 2,
        "file-loaded: present shader not appended twice")
end

-- ---------------------------------------------------------------------------
-- regression checks: empty opt restore, VFG retarget on manual k, sweep floor,
-- detect_output (truehdr enable=no & native HDR), render_fps pacing
-- ---------------------------------------------------------------------------
do
    local player = new_player(sdr(165, 24, {
        ["estimated-vf-fps"] = 82.5,
        ["vf"] = "@hwup:hwup,@vfg:vfg:fps=auto:max-fps=165",
        ["vo"] = "gpu",
        ["current-vo"] = "gpu",
        ["hdr-compute-peak"] = "auto",
    }))
    local api = player.api
    api.enable()
    contains(player.osd, "pacing locked", "status: render_fps 82.5 on 165 Hz locks k=2")
    equal(api.state.subframes, 2, "auto: 165 Hz lands on k=2 (82.5 Hz sweep)")
    player.bindings["beam-subframes-cycle"]()
    equal(api.state.subframes, 3, "cycle: 2 -> 3")
    equal(player.count("vf-command", "vfg", "out-fps", "55"), 1,
        "cycle: retargets VFG to 165/3 = 55")
    player.messages["beam"]("subframes", "5")
    equal(player.count("vf-command", "vfg", "out-fps", "33"), 1,
        "message subframes: retargets VFG to 165/5 = 33")
    player.bindings["beam-subframes-auto"]()
    equal(api.state.subframes, 2, "auto: restores k=2 from sweep_hz (72 Hz), not source_fps")
    equal(player.count("vf-command", "vfg", "out-fps", "82.5"), 2,
        "auto: retargets VFG back to 82.5")
    api.set_sweep_hz(600)
    near(api.state.subframes, 1.001,
         "set_sweep_hz: a rate above the refresh runs one sweep per refresh", 1e-9)
    api.set_sweep_hz(10)
    equal(api.state.subframes, 3, "set_sweep_hz: clamped to 48 Hz floor (165/48 -> k=3)")

    -- x6: `beam sweep 144` on a 165 Hz panel must hold k = 165/144 = 1.1458,
    -- not round to 2 (82.5 Hz) or 3 (55 Hz), and must run at full depth.
    api.set_sweep_hz(144)
    near(api.state.subframes, 165 / 144, "set_sweep_hz: x6 keeps the fractional ratio", 1e-9)
    near(last_out_fps(player), 144, "set_sweep_hz: VFG retargeted to 144 fps", 1e-6)
    near(api.state.strength, 1.0, "set_sweep_hz: full depth for the x6 sweep")
    player.messages["beam"]("subframes", "1.147")
    near(api.state.subframes, 1.147, "message subframes: fractional k accepted", 1e-9)
    near(last_out_fps(player), 165 / 1.147,
         "message subframes: retargets VFG to 165/1.147", 1e-6)
    player.messages["beam"]("strength", "0.3")
    player.messages["beam"]("strength")
    near(api.state.strength, 1.0,
         "message strength: auto follows the x6 sweep, not just the refresh", 1e-9)

    -- The phase counter is only trustworthy on vo=gpu-next, and the peak pass
    -- runs the hook twice; both are forced while the beam is on and restored
    -- afterwards.
    equal(player.props["hdr-compute-peak"], "no", "enable: peak pass disabled")
    equal(player.props["vo"], "gpu-next", "enable: vo forced to gpu-next")
    assert(api.state.on, "enable: beam is on")
    api.disable()
    equal(player.props["hdr-compute-peak"], "auto", "disable: peak pass restored")
    equal(player.props["vo"], "gpu", "disable: vo restored")
    api.disable()
    equal(player.props["glsl-shader-opts"], "", "disable: clears previously empty glsl-shader-opts")
end

-- ---------------------------------------------------------------------------
-- enable() reports the VFG rate it just requested, not the pre-retarget
-- estimated-vf-fps (which made the startup OSD show a false mismatch)
-- ---------------------------------------------------------------------------
do
    local player = new_player(sdr(165, 24, {
        ["estimated-vf-fps"] = 96,   -- integer-multiplier rate, before out-fps lands
        ["vf"] = "@hwup:hwup,@vfg:vfg:fps=auto:max-fps=165",
    }))
    player.api.enable()
    contains(player.osd, "pacing locked",
        "enable: status uses the requested 82.5 fps, not the stale 96")
    assert(player.osd:find("82.5", 1, true), "enable: status shows the target rate")
end

do
    local player = new_player(sdr(165, 24))
    player.native = {
        vf = {
            { name = "truehdr", enabled = true, params = { enable = "no", luminance = "630" } },
        },
    }
    -- SDR target: the VO tone-mapped whatever the chain produced, so the hook
    -- sees display codes no matter that truehdr/luminance is configured.
    player.props["video-out-params/gamma"] = "bt.1886"
    local tr, peak = player.api.detect_output()
    equal(tr, "sdr", "detect_output: SDR target -> sdr")
    equal(peak, 100, "detect_output: SDR reports reference white")

    -- Same chain, HDR target: now the hook gets ST.2084 codes and the peak is
    -- the peak the display is driven at, not the chain's internal luminance.
    player.props["video-out-params/gamma"] = "pq"
    player.props["video-out-params/max-luma"] = 654
    player.native.vf[1].params.enable = "yes"
    tr, peak = player.api.detect_output()
    equal(tr, "pq", "detect_output: PQ target -> pq even with truehdr on")
    equal(peak, 654, "detect_output: peak from the compositor max-luma")

    -- PQ target without max-luma falls back to target-peak, then to 1000.
    player.props["video-out-params/max-luma"] = nil
    player.props["target-peak"] = 1000
    tr, peak = player.api.detect_output()
    equal(tr, "pq", "detect_output: native PQ stays PQ")
    equal(peak, 1000, "detect_output: falls back to target-peak")

    player.props["target-peak"] = nil
    tr, peak = player.api.detect_output()
    equal(peak, 1000, "detect_output: last resort 1000 nits")

    -- A bare PQ target with no HDR compositor reports the 10000-nit encoding
    -- ceiling as max-luma; that is not a display peak.
    player.props["video-out-params/max-luma"] = 10000
    player.props["target-peak"] = 630
    tr, peak = player.api.detect_output()
    equal(peak, 630, "detect_output: 10000 sentinel ignored, target-peak used")
end

do
    -- Packaged install: mpv resolves ~~/shaders/crt-beam-sim.glsl relative to
    -- the config dir, which may be a system path. The script must append the
    -- resolved file, and remove that same entry rather than the constant.
    local player = new_player(sdr(240, 24))
    local shader = root .. "/shaders/crt-beam-sim.glsl"
    mp.command_native = function(args)
        if args[1] == "expand-path" then return shader end
        error("unexpected command_native: " .. tostring(args[1]))
    end
    player.api.enable()
    equal(player.count("change-list", "glsl-shaders", "append", shader), 1,
        "packaged: the resolved shader path is appended")
    player.api.disable()
    equal(player.count("change-list", "glsl-shaders", "remove", shader), 1,
        "packaged: disable removes the entry it appended")
end

print("beam-sim tests passed")
