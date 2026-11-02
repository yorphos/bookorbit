local Metrics = require("bookorbit_board_metrics")
local Theme = {
    listRow = 62,
    margin = 20,
    gap = 10,
    button = 44,
    nav = 64,
    row = 112,
    title = 26,
    heading = 22,
    body = 16,
    small = 13,
    brand = 29,
}
Theme.px, Theme.ink = Metrics.px, Metrics.INK

-- Row count follows KOReader's font/interface scale, not a fixed device count.
function Theme.geometry(w, h)
    local px = Theme.px
    local header = px(118)
    local footer = px(Theme.nav)
    local body = h - header - footer - px(12)
    return {
        w = w,
        h = h,
        margin = px(Theme.margin),
        content = w - 2 * px(Theme.margin),
        header = header,
        footer = footer,
        body = body,
        rows = math.max(1, math.floor((body - px(210)) / px(Theme.listRow + 7))),
    }
end

return Theme
