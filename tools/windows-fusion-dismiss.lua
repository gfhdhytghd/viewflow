-- Observe actual button presses without consuming the click or changing focus.
local function dismiss_windows_start_outside()
    local point = hl.get_cursor_pos()
    local menu = nil
    for _, window in ipairs(hl.get_windows()) do
        if window.mapped and window.visible and (window.class:match('^ViewflowReverse%-WindowsStart%-') or window.class:match('^ViewflowReverse%-IME%-')) then
            local at, size = window.at, window.size
            if point.x >= at.x and point.x < at.x + size.x and point.y >= at.y and point.y < at.y + size.y then
                return
            end
            if window.class:match('^ViewflowReverse%-WindowsStart%-') then menu = window end
        end
    end
    if menu then
        hl.exec_cmd(os.getenv('HOME') .. '/.local/bin/viewflow-windows dismiss-start --window-class ' .. menu.class)
    end
end
for _, button in ipairs({272, 273, 274, 275, 276}) do
    hl.bind('mouse:' .. button, dismiss_windows_start_outside, {
        non_consuming = true, ignore_mods = true,
        description = 'Dismiss Windows Start on an outside click',
    })
end
