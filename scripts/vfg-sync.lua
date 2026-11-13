-- Keep VFG's output cap aligned with the active display refresh rate.

local FALLBACK_FPS = 60
local MAX_FPS = 1000
local last_cap
local last_chain

local function current_cap()
    local hz = mp.get_property_number("display-fps", 0)
    if type(hz) ~= "number" or hz ~= hz or hz < 20 or hz > MAX_FPS then
        -- Keep auto interpolation bounded when the VO cannot report a mode.
        return FALLBACK_FPS
    end
    return hz
end

local function apply(force)
    local cap = current_cap()
    if not force and cap == last_cap then
        return
    end

    local _, err = mp.command_native({
        "vf-command", "vfg", "max-fps", string.format("%.17g", cap),
    })
    if err == nil then
        last_cap = cap
    end
end

local function on_filter_change(_, chain)
    if last_chain ~= nil and chain ~= last_chain then
        last_cap = nil
    end
    last_chain = chain
    apply()
end

local function on_display_change()
    apply()
end

mp.observe_property("display-fps", "number", on_display_change)
mp.observe_property("vf", "string", on_filter_change)

mp.register_event("start-file", function()
    last_cap = nil
end)
mp.register_event("file-loaded", function()
    apply(true)
end)
mp.register_event("video-reconfig", function()
    apply(true)
end)
