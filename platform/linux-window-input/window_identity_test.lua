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

-- Run the exact production graceful close request without a compositor.
local closePipe = assert(io.popen(arg[1] .. ' close'))
local command = closePipe:read('*a'); assert(closePipe:close())
local function closes(window)
    local count = 0
    local env = {assert=assert, hl={get_window=function() return window end,
        dsp={window={close=function(request)
            assert(request.window == window); return request
        end}}, dispatch=function() count=count+1 end}}
    local ok = pcall(assert(load(command, 'graceful close', 't', env)))
    return ok and count == 1
end
assert(closes({mapped=true, pid=2327048, stable_id='180001ed'}))
assert(closes({mapped=false, pid=2327048, stable_id='180001ed'}))
assert(not closes({mapped=true, pid=2327049, stable_id='180001ed'}))
assert(not closes({mapped=true, pid=2327048, stable_id='different'}))
assert(not closes(nil))
