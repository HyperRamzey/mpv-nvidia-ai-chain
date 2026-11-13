local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/tests/[^/]+$") or "."
local sync_script = root .. "/scripts/vfg-sync.lua"

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s",
        label, tostring(expected), tostring(actual)))
end

local function check_cap(call, expected)
    equal(call[1], "vf-command", "command")
    equal(call[2], "vfg", "filter label")
    equal(call[3], "max-fps", "filter command")
    local actual = tonumber(call[4])
    assert(actual and math.abs(actual - expected) < 1e-9,
        string.format("expected max-fps %.12g, got %s", expected, tostring(call[4])))
end

local function new_player(fps)
    local observers, events, calls = {}, {}, {}
    local player = {fps = fps, calls = calls, observers = observers, events = events}
    local mp = {}

    function mp.get_property_number(name, default)
        equal(name, "display-fps", "queried property")
        if player.fps == nil then
            return default
        end
        return player.fps
    end

    function mp.observe_property(name, _, callback)
        observers[name] = callback
    end

    function mp.register_event(name, callback)
        events[name] = callback
    end

    function mp.command_native(args)
        calls[#calls + 1] = args
        if player.fail_next then
            player.fail_next = false
            return nil, "filter unavailable"
        end
        return {}
    end

    _G.mp = mp
    dofile(sync_script)

    function player.observe(name, value)
        observers[name](name, value)
    end

    function player.set_fps(value)
        player.fps = value
        observers["display-fps"]("display-fps", value)
    end

    return player
end

local player = new_player(165)
player.observe("vf", "@vfg:vfg:fps=auto")
check_cap(player.calls[1], 165)
player.observe("display-fps", 165)
equal(#player.calls, 1, "unchanged refresh is cached")

player.events["start-file"]()
equal(#player.calls, 1, "start-file waits for the new chain")
player.events["file-loaded"]()
equal(#player.calls, 2, "same refresh reapplied after file rebuild")
check_cap(player.calls[2], 165)

player.observe("vf", "@vfg:vfg:fps=auto,mode=high")
equal(#player.calls, 3, "changed filter chain reapplies same refresh")
player.set_fps(120)
check_cap(player.calls[4], 120)
player.set_fps(144)
check_cap(player.calls[5], 144)
player.set_fps(59.94)
check_cap(player.calls[6], 59.94)
player.set_fps(59.94)
equal(#player.calls, 6, "unchanged fractional refresh is cached")
player.set_fps(360)
check_cap(player.calls[7], 360)
player.events["video-reconfig"]()
equal(#player.calls, 8, "video reconfiguration reapplies the refresh")
check_cap(player.calls[8], 360)

local missing = new_player(nil)
missing.observe("vf", "@vfg:vfg:fps=auto")
check_cap(missing.calls[1], 60)
missing.set_fps(120)
check_cap(missing.calls[2], 120)
missing.set_fps(nil)
check_cap(missing.calls[3], 60)

local retry = new_player(120)
retry.fail_next = true
retry.observe("vf", "@vfg:vfg:fps=auto")
equal(#retry.calls, 1, "initial command attempted")
retry.observe("display-fps", 120)
equal(#retry.calls, 2, "failed command is retried")
check_cap(retry.calls[2], 120)

print("vfg-sync refresh tests passed")
