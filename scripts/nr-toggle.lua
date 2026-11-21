-- nr-toggle.lua -- full control & keybinds for DLSS 5 Neural Render (and VFG).
-- Modelled after NeuralScreen (https://github.com/perseval-BLR/NeuralScreen).

local mp    = require "mp"
local msg   = require "mp.msg"
local utils = require "mp.utils"

local HOME   = os.getenv("HOME") or ""
local STATE  = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/mpv-ai-nr"
local USERS  = STATE .. "/users"
local HELPER = HOME .. "/.local/bin/dlssnr-helper"
local PID    = tostring(utils.getpid())

-- Active state
local nr_on = false
local current_passes = 1
local busy  = false
local last_cmd = -10

local PROFILES = { "faithful", "natural", "cinematic", "extreme" }
local SCALES   = { 0.25, 0.50, 0.65, 0.75, 1.00 }
local SKINS    = { -1.0, 0.0, 0.5, 1.0, 1.5, 2.0 }

local PROFILE_DEFS = {
    faithful  = { style = 0, intensity = 0.70, localtone = 0.25, localstructure = 0.75, skin = -1.0, automask = 1, sharpness = 0.0 },
    natural   = { style = 1, intensity = 1.00, localtone = 0.50, localstructure = 1.00, skin = -1.0, automask = 1, sharpness = 0.0 },
    cinematic = { style = 2, intensity = 1.00, localtone = 0.90, localstructure = 1.50, skin =  1.0, automask = 1, sharpness = 0.0 },
    extreme   = { style = 2, intensity = 1.00, localtone = 1.50, localstructure = 1.50, skin =  1.5, automask = 1, sharpness = 0.0 },
}

local seek_timer = nil
local function refresh_if_paused()
    if mp.get_property_bool("pause") then
        if seek_timer then seek_timer:kill() end
        seek_timer = mp.add_timeout(0.03, function()
            seek_timer = nil
            if mp.get_property_bool("pause") then
                mp.commandv("seek", "0", "relative+exact")
            end
        end)
    end
end

local state = {
    profile        = "cinematic",
    work_scale     = 0.50,
    intensity      = 1.00,
    localtone      = 0.90,
    localstructure = 1.50,
    skin           = -1.0,
    sharpness      = 0.00,
    automask       = 1,
    style          = 2,
    vfg            = "auto",
}

local function osd(text, secs)
    mp.osd_message(text, secs or 2.5)
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function write_all(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text or "")
    f:close()
    return true
end

local function pid_alive(pid)
    local n = tonumber(pid)
    return n ~= nil and file_exists("/proc/" .. n .. "/stat")
end

local function is_me(pid)
    return tostring(tonumber(pid) or pid) == PID
end

utils.subprocess({ args = { "mkdir", "-p", USERS }, cancellable = false })

local function mark_active()
    write_all(USERS .. "/" .. PID, "")
end

local function unmark_active()
    os.remove(USERS .. "/" .. PID)
end

local function other_users()
    local count = 0
    for _, name in ipairs(utils.readdir(USERS) or {}) do
        local pid = name:match("^(%d+)$")
        if pid and not is_me(pid) then
            if pid_alive(pid) then
                count = count + 1
            else
                os.remove(USERS .. "/" .. name)
            end
        end
    end
    return count
end

local function find_dlssnr()
    for _, f in ipairs(mp.get_property_native("vf") or {}) do
        if f.label == "dlssnr" then
            return f
        end
    end
    return nil
end

local function helper(verb, opts, cb)
    opts = opts or {}
    local t = {
        name           = "subprocess",
        args           = { "/bin/sh", "-c", 'exec "$0" "$1" >/dev/null 2>&1', HELPER, verb },
        playback_only  = false,
        capture_stdout = opts.capture == true,
        capture_stderr = opts.capture == true,
        detach         = opts.detach == true,
    }
    if opts.detach then
        mp.command_native(t)
        if cb then cb(true) end
        return
    end
    mp.command_native_async(t, function(ok, res)
        local code = res and res.status or -1
        local out = ""
        if opts.capture then
            out = (res and res.stdout or "") .. (res and res.stderr or "")
        end
        if cb then cb(ok and code == 0, out) end
    end)
end

local function send_dlssnr(param, val, cb)
    last_cmd = mp.get_time()
    mp.command_native_async(
        { "vf-command", "dlssnr", param, tostring(val) },
        function(ok, _res, err)
            if not ok then
                msg.warn("vf-command dlssnr " .. param .. " " .. tostring(val) .. ": " .. tostring(err))
            end
            if cb then cb(ok) end
        end
    )
end

local function sync_all_settings()
    send_dlssnr("profile", state.profile)
    send_dlssnr("work_scale", state.work_scale)
    send_dlssnr("intensity", state.intensity)
    send_dlssnr("localtone", state.localtone)
    send_dlssnr("localstructure", state.localstructure)
    send_dlssnr("skin", state.skin)
    send_dlssnr("sharpness", state.sharpness)
    send_dlssnr("automask", state.automask)
end

local function enable(passes_target)
    local p = passes_target or current_passes
    if p <= 0 then p = 1 end
    current_passes = p

    if busy then return end

    if nr_on then
        helper("start", {}, function(ok)
            if ok then
                send_dlssnr("passes", current_passes)
                sync_all_settings()
            end
        end)
        osd(string.format("DLSS 5 NR: ON (%d pass%s)", current_passes, current_passes > 1 and "es" or ""))
        refresh_if_paused()
        return
    end

    if not find_dlssnr() then
        osd("DLSS 5 NR: filter not in this chain (use mpv-ai)", 3)
        return
    end

    busy = true
    osd("DLSS 5 NR: starting helper...", 0)
    helper("start", {}, function(ok, out)
        if not ok then
            busy = false
            osd("DLSS 5 NR: helper failed to start", 3)
            msg.err(out)
            return
        end
        mark_active()
        nr_on = true
        send_dlssnr("passes", current_passes, function()
            sync_all_settings()
            busy = false
            osd(string.format("DLSS 5 NR: ON (%d pass%s)", current_passes, current_passes > 1 and "es" or ""))
            refresh_if_paused()
        end)
    end)
end

local function disable()
    if busy then return end
    local was_on = nr_on
    nr_on = false
    busy = true

    unmark_active()
    if find_dlssnr() then
        send_dlssnr("passes", 0)
    end

    local others = other_users()
    if was_on and others == 0 then
        osd("DLSS 5 NR: OFF")
        refresh_if_paused()
        helper("stop", {}, function()
            busy = false
        end)
    else
        busy = false
        if others > 0 then
            osd("DLSS 5 NR: OFF (helper kept for another player)")
        else
            osd("DLSS 5 NR: OFF")
        end
        refresh_if_paused()
    end
end

local function toggle()
    if nr_on then
        disable()
    else
        enable(current_passes)
    end
end

local function cycle_passes()
    if not nr_on then
        enable(1)
    elseif current_passes == 1 then
        enable(2)
    else
        disable()
    end
end

local function set_profile(name)
    local n = (name or ""):lower()
    local def = PROFILE_DEFS[n]
    if not def then
        osd("Unknown profile: " .. tostring(name), 2)
        return
    end
    state.profile = n
    state.style = def.style
    state.intensity = def.intensity
    state.localtone = def.localtone
    state.localstructure = def.localstructure
    state.skin = def.skin
    state.sharpness = def.sharpness
    state.automask = def.automask
    if nr_on then
        send_dlssnr("profile", state.profile)
    end
    osd(string.format("DLSS 5 Profile: %s", state.profile:upper()))
    refresh_if_paused()
end

local function cycle_profile()
    local idx = 1
    for i, name in ipairs(PROFILES) do
        if name == state.profile then
            idx = i
            break
        end
    end
    idx = (idx % #PROFILES) + 1
    set_profile(PROFILES[idx])
end

local function adjust_work_scale(dir)
    local cur_idx = 2
    for i, s in ipairs(SCALES) do
        if math.abs(s - state.work_scale) < 0.01 then
            cur_idx = i
            break
        end
    end
    local new_idx = math.max(1, math.min(#SCALES, cur_idx + dir))
    state.work_scale = SCALES[new_idx]
    if nr_on then
        send_dlssnr("work_scale", state.work_scale)
    end
    local label = state.work_scale == 1.0 and "100% (Native)" or string.format("%d%% (Boost)", math.floor(state.work_scale * 100))
    osd(string.format("DLSS 5 Working Scale: %s", label))
    refresh_if_paused()
end

local function adjust_intensity(delta)
    state.intensity = math.max(0.0, math.min(1.0, state.intensity + delta))
    if nr_on then
        send_dlssnr("intensity", state.intensity)
    end
    osd(string.format("DLSS 5 Intensity: %.2f", state.intensity))
    refresh_if_paused()
end

local function adjust_localtone(delta)
    state.localtone = math.max(0.0, math.min(2.0, state.localtone + delta))
    if nr_on then
        send_dlssnr("localtone", state.localtone)
    end
    osd(string.format("DLSS 5 Local Tone: %.2f", state.localtone))
    refresh_if_paused()
end

local function adjust_localstructure(delta)
    state.localstructure = math.max(0.0, math.min(2.0, state.localstructure + delta))
    if nr_on then
        send_dlssnr("localstructure", state.localstructure)
    end
    osd(string.format("DLSS 5 Local Structure: %.2f", state.localstructure))
    refresh_if_paused()
end

local function adjust_sharpness(delta)
    state.sharpness = math.max(0.0, math.min(1.0, state.sharpness + delta))
    if nr_on then
        send_dlssnr("sharpness", state.sharpness)
    end
    osd(string.format("DLSS 5 Sharpness: %.2f", state.sharpness))
    refresh_if_paused()
end

local function cycle_skin()
    local idx = 1
    for i, s in ipairs(SKINS) do
        if math.abs(s - state.skin) < 0.01 then
            idx = i
            break
        end
    end
    idx = (idx % #SKINS) + 1
    state.skin = SKINS[idx]
    if nr_on then
        send_dlssnr("skin", state.skin)
    end
    local label = state.skin < 0 and "Off" or string.format("%.1f", state.skin)
    osd(string.format("DLSS 5 Skin Protection: %s", label))
    refresh_if_paused()
end

local function toggle_automask()
    state.automask = state.automask == 1 and 0 or 1
    if nr_on then
        send_dlssnr("automask", state.automask)
    end
    osd(string.format("DLSS 5 AutoMask (UI/Text): %s", state.automask == 1 and "ON" or "OFF"))
    refresh_if_paused()
end

local function toggle_vfg()
    if state.vfg == "auto" then
        state.vfg = "off"
    else
        state.vfg = "auto"
    end
    mp.command_native_async({ "vf-command", "vfg", "fps", state.vfg })
    osd(string.format("DLSS Frame Gen (VFG): %s", state.vfg:upper()))
    refresh_if_paused()
end

local function show_status()
    local nr_status = nr_on and string.format("ON (%d pass%s)", current_passes, current_passes > 1 and "es" or "") or "OFF"
    local scale_str = state.work_scale == 1.0 and "100% (Native)" or string.format("%d%% (Boost)", math.floor(state.work_scale * 100))
    local skin_str  = state.skin < 0 and "Off" or string.format("%.1f", state.skin)

    local txt = string.format(
        "【 NVIDIA DLSS 5 Neural Render 】\n" ..
        "• State: %s\n" ..
        "• Profile: %s | Work Scale: %s\n" ..
        "• Intensity: %.2f | Sharpness: %.2f\n" ..
        "• Local Tone: %.2f | Structure: %.2f\n" ..
        "• Skin Protection: %s | AutoMask: %s\n" ..
        "• Frame Gen (VFG): %s",
        nr_status, state.profile:upper(), scale_str,
        state.intensity, state.sharpness,
        state.localtone, state.localstructure,
        skin_str, state.automask == 1 and "ON" or "OFF",
        state.vfg:upper()
    )
    osd(txt, 4)
end

-- Re-apply on profile/file changes
mp.observe_property("vf", "native", function(_, vf)
    if not nr_on or busy or (mp.get_time() - last_cmd) < 2 then return end
    for _, f in ipairs(vf or {}) do
        if f.label == "dlssnr" then
            local passes = tonumber(f.params and f.params.passes)
            if passes ~= current_passes then
                mp.add_timeout(0, function()
                    if nr_on and not busy then
                        send_dlssnr("passes", current_passes)
                        sync_all_settings()
                    end
                end)
            end
            return
        end
    end
end)

mp.register_event("file-loaded", function()
    if nr_on then
        mp.add_timeout(0.3, function()
            if nr_on and not busy and find_dlssnr() then
                send_dlssnr("passes", current_passes)
                sync_all_settings()
            end
        end)
    end
end)

mp.register_event("shutdown", function()
    if not nr_on and not busy then return end
    unmark_active()
    if other_users() > 0 then return end
    if busy then
        mp.command_native({
            name          = "subprocess",
            args          = { "/bin/sh", "-c", 'sleep 2; exec "$0" stop >/dev/null 2>&1', HELPER },
            playback_only = false,
            detach        = true,
            capture_stdout = false,
            capture_stderr = false,
        })
    else
        helper("stop", { detach = true })
    end
end)

-- Script bindings (can be called by input.conf)
mp.add_key_binding(nil, "dlssnr-toggle", toggle)
mp.add_key_binding(nil, "dlssnr-on", function() enable(1) end)
mp.add_key_binding(nil, "dlssnr-on-2pass", function() enable(2) end)
mp.add_key_binding(nil, "dlssnr-off", disable)
mp.add_key_binding(nil, "dlssnr-passes-cycle", cycle_passes)
mp.add_key_binding(nil, "dlssnr-profile-cycle", cycle_profile)
mp.add_key_binding(nil, "dlssnr-scale-up", function() adjust_work_scale(1) end)
mp.add_key_binding(nil, "dlssnr-scale-down", function() adjust_work_scale(-1) end)
mp.add_key_binding(nil, "dlssnr-intensity-up", function() adjust_intensity(0.05) end)
mp.add_key_binding(nil, "dlssnr-intensity-down", function() adjust_intensity(-0.05) end)
mp.add_key_binding(nil, "dlssnr-localtone-up", function() adjust_localtone(0.10) end)
mp.add_key_binding(nil, "dlssnr-localtone-down", function() adjust_localtone(-0.10) end)
mp.add_key_binding(nil, "dlssnr-localstructure-up", function() adjust_localstructure(0.10) end)
mp.add_key_binding(nil, "dlssnr-localstructure-down", function() adjust_localstructure(-0.10) end)
mp.add_key_binding(nil, "dlssnr-sharpness-up", function() adjust_sharpness(0.10) end)
mp.add_key_binding(nil, "dlssnr-sharpness-down", function() adjust_sharpness(-0.10) end)
mp.add_key_binding(nil, "dlssnr-skin-cycle", cycle_skin)
mp.add_key_binding(nil, "dlssnr-automask-toggle", toggle_automask)
mp.add_key_binding(nil, "vfg-toggle", toggle_vfg)
mp.add_key_binding(nil, "dlssnr-status", show_status)

-- Script messages (console support)
mp.register_script_message("dlssnr", function(cmd, arg1, arg2)
    cmd = (cmd or ""):lower()
    if cmd == "toggle" then
        toggle()
    elseif cmd == "on" then
        enable(tonumber(arg1) or 2)
    elseif cmd == "off" then
        disable()
    elseif cmd == "profile" or cmd == "preset" then
        if arg1 and arg1 ~= "" then
            set_profile(arg1)
        else
            cycle_profile()
        end
    elseif cmd == "passes" then
        local p = tonumber(arg1)
        if p and p > 0 then
            enable(p)
        else
            disable()
        end
    elseif cmd == "scale" or cmd == "work_scale" then
        local s = tonumber(arg1)
        if s then
            state.work_scale = s
            if nr_on then send_dlssnr("work_scale", s) end
            osd(string.format("DLSS 5 Work Scale: %.2f", s))
            refresh_if_paused()
        end
    elseif cmd == "intensity" then
        local v = tonumber(arg1)
        if v then
            state.intensity = v
            if nr_on then send_dlssnr("intensity", v) end
            osd(string.format("DLSS 5 Intensity: %.2f", v))
            refresh_if_paused()
        end
    elseif cmd == "status" or cmd == "info" then
        show_status()
    elseif cmd == "refresh" then
        refresh_if_paused()
    else
        osd("dlssnr commands: toggle, on, off, profile <name>, scale <0.25..1.0>, status", 4)
    end
end)

mp.register_script_message("dlssnr-toggle", toggle)
mp.register_script_message("dlssnr-on", function(p) enable(tonumber(p) or 1) end)
mp.register_script_message("dlssnr-on-2pass", function() enable(2) end)
mp.register_script_message("dlssnr-off", disable)
mp.register_script_message("dlssnr-profile", set_profile)
mp.register_script_message("dlssnr-profile-cycle", cycle_profile)
mp.register_script_message("dlssnr-status", show_status)
mp.register_script_message("vfg-toggle", toggle_vfg)
mp.register_script_message("refresh", refresh_if_paused)

-- Default direct hotkeys
mp.add_key_binding("Ctrl+Alt+n", "dlssnr-on-default", function() enable(1) end)
mp.add_key_binding("Ctrl+Alt+Shift+n", "dlssnr-off-default", disable)
