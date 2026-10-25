-- vfg-sync.lua -- keep VFG's output cap equal to the current display refresh.
--
-- vfg re-reads max-fps every frame and re-decides the fps=auto multiplier on
-- the next frame, so the cap does not have to be a number baked into ai.conf.
-- That matters because the multiplier is a function of source fps AND refresh:
--
--   24 fps -> x4 =  96      30 fps -> x4 = 120      48 fps -> x3 = 144
--   60 fps -> x2 = 120     120 fps -> 240, nothing fits -> passthrough
--
-- With the cap at the refresh (165 here, but 144/120/60 are one mode switch
-- away) the choice follows the panel instead of a fixed 110 that silently
-- turned 60 fps sources into passthrough.
--
-- No-op unless a filter labelled @vfg exists: plain mpv and the Dolby Vision
-- P5 profiles never have one, and the command simply fails there.

local last

local function apply()
    local hz = mp.get_property_number("display-fps", 0)
    if not hz or hz < 20 then
        return
    end
    local cap = math.floor(hz + 0.5)
    if cap == last then
        return
    end
    -- Returns nil, err when the chain does not exist yet (file not loaded,
    -- P5 profile, plain mpv); leave `last` unset so the next trigger retries.
    -- The label is the one from the chain string without its "@" sigil:
    -- `vf=...,@vfg:vfg:...` is addressed as just "vfg".
    local _, err = mp.command_native({
        "vf-command", "vfg", "max-fps", tostring(cap),
    })
    if err == nil then
        last = cap
    end
end

mp.observe_property("display-fps", "number", apply)
-- The chain is rebuilt on file load and whenever a resolution profile flips,
-- which can happen after display-fps was first reported.
mp.observe_property("vf", "string", apply)
