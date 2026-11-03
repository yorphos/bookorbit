--[[--
What the hub did lately, for its Diagnostics screen: recent events and errors,
and how long background requests took in each mode. Errors are sent to the
server log only when the reader turned error reports on.
]]
local Diag = {}

local MAX_EVENTS = 40
local timings = {}

local function log(settings)
    if type(settings.hub_diag_log) ~= "table" then
        settings.hub_diag_log = {}
    end
    return settings.hub_diag_log
end

-- kind: "info", "error" or "sync". Kept in settings, newest last.
function Diag.event(settings, kind, text)
    local events = log(settings)
    events[#events + 1] = { t = os.time(), kind = kind, text = tostring(text or ""):sub(1, 300) }
    while #events > MAX_EVENTS do
        table.remove(events, 1)
    end
end

function Diag.events(settings)
    return log(settings)
end

function Diag.lastError(settings)
    local events = log(settings)
    for i = #events, 1, -1 do
        if events[i].kind == "error" then
            return events[i]
        end
    end
end

-- One request's duration, by how it ran: "subprocess" or "direct".
function Diag.timing(mode, seconds)
    local t = timings[mode] or { count = 0, total = 0 }
    t.count, t.total, t.last = t.count + 1, t.total + seconds, seconds
    timings[mode] = t
end

function Diag.timings()
    local result = {}
    for mode, t in pairs(timings) do
        result[mode] = { count = t.count, average = t.total / math.max(1, t.count), last = t.last }
    end
    return result
end

function Diag.reset()
    timings = {}
end

-- Records an error and, with the reader's consent, queues a report for the server log.
function Diag.error(hub, where, err, trace)
    local settings = hub.plugin.settings
    local message = tostring(err or "unknown error")
    Diag.event(settings, "error", where .. ": " .. message)
    if settings.hub_error_reports ~= true then
        return
    end
    require("bookorbit_hub_outbox").add(hub, {
        method = "POST",
        path = "/koreader/plugin/hub/error-reports",
        payload = {
            message = message:sub(1, 2000),
            where = tostring(where):sub(1, 200),
            version = tostring(hub.plugin.PLUGIN_VERSION or ""):sub(1, 64),
            trace = trace and tostring(trace):sub(1, 4000) or nil,
        },
        label = "Error report",
        kind = "report",
    })
end

-- Runs fn, and records instead of raising an error inside it.
function Diag.guard(hub, where, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
        local message = tostring(err):match("^[^\n]*") or tostring(err)
        Diag.error(hub, where, message, err)
        require("bookorbit_toast").error("Something went wrong. Details are in Diagnostics.")
    end
    return ok
end

return Diag
