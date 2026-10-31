-- Execute the production guard against both supported Lua object contracts.
local pipe = assert(io.popen(arg[1]))
local guard = pipe:read('*a')
assert(pipe:close())
local function accepts(window)
    local env = {hl = {get_window = function(selector)
        assert(selector == 'address:0x55675023acb0')
        return window
    end}, assert = assert}
    return pcall(assert(load(guard, 'window guard', 't', env)))
end
assert(accepts({mapped=true, pid=2327048, stable_id='180001ed'}))
assert(accepts({mapped=true, pid=2327048, stable_id=0x180001ed}))
assert(not accepts({mapped=true, pid=2327048, stable_id='180001ee'}))
assert(not accepts({mapped=true, pid=2327048, stable_id=0x180001ee}))
assert(not accepts({mapped=true, pid=2327049, stable_id='180001ed'}))
assert(not accepts({mapped=false, pid=2327048, stable_id='180001ed'}))
assert(not accepts({mapped=true, pid=2327048}))
assert(not accepts(nil))
