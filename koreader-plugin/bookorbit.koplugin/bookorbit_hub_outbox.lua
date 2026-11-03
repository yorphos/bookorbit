--[[--
Actions taken without Wi-Fi, and Roulette decisions, wait here until BookOrbit
can be reached. Each waits in settings, so a restart keeps them, and goes out
in order, one at a time, in the background.

Only actions that are safe to send twice are queued: wishlist and collection
changes, requests (BookOrbit joins a second request for the same book to the
first) and Roulette decisions, whose event id makes a repeat a no-op.
]]
local Outbox = {}

local RETRY_SECONDS = 60
local MAX_ITEMS = 200
local MAX_ATTEMPTS = 8

function Outbox.uuid()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(16)
    if f then
        f:close()
    end
    if not bytes or #bytes < 16 then
        local parts = {}
        for i = 1, 16 do
            parts[i] = string.char(math.random(0, 255))
        end
        bytes = table.concat(parts)
    end
    local hex = bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end)
    return hex:sub(1, 8)
        .. "-"
        .. hex:sub(9, 12)
        .. "-4"
        .. hex:sub(14, 16)
        .. "-8"
        .. hex:sub(18, 20)
        .. "-"
        .. hex:sub(21, 32)
end

local function store(hub)
    local saved = hub.plugin.settings.hub_outbox
    if type(saved) ~= "table" or saved.account ~= hub.account then
        saved = { account = hub.account, items = {} }
        hub.plugin.settings.hub_outbox = saved
    end
    return saved
end

function Outbox.items(hub)
    return store(hub).items
end

function Outbox.count(hub)
    return #Outbox.items(hub)
end

-- entry: { method, path, payload, label, kind, key }. A queued entry with the
-- same key is replaced: adding then removing a wishlist book sends only the last.
function Outbox.add(hub, entry)
    local items = Outbox.items(hub)
    entry.id = entry.id or Outbox.uuid()
    entry.created = entry.created or os.time()
    entry.attempts = 0
    if entry.key then
        for i = #items, 1, -1 do
            if items[i].key == entry.key then
                table.remove(items, i)
            end
        end
    end
    items[#items + 1] = entry
    while #items > MAX_ITEMS do
        table.remove(items, 1)
    end
    G_reader_settings:flush()
    Outbox.drain(hub)
    return entry
end

function Outbox.remove(hub, id)
    local items = Outbox.items(hub)
    for i = #items, 1, -1 do
        if items[i].id == id then
            table.remove(items, i)
            G_reader_settings:flush()
            return true
        end
    end
    return false
end

-- The newest queued entry of a kind, for undoing it before it is sent.
function Outbox.last(hub, kind)
    local items = Outbox.items(hub)
    for i = #items, 1, -1 do
        if items[i].kind == kind then
            return items[i]
        end
    end
end

function Outbox.clear(hub)
    store(hub).items = {}
    G_reader_settings:flush()
end

local function permanent(err)
    local code = tonumber(err)
    return code and code >= 400 and code < 500 and code ~= 408 and code ~= 429
end

-- Sends queued entries one at a time while BookOrbit answers. Stops at the
-- first entry that cannot reach it and tries again a minute later.
function Outbox.drain(hub)
    if hub.closed or hub.outboxDraining then
        return
    end
    local items = Outbox.items(hub)
    local entry = items[1]
    if not entry then
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if hub.busy or not NetworkMgr:isConnected() then
        Outbox.retryLater(hub, hub.busy and 3 or RETRY_SECONDS)
        return
    end
    hub.outboxDraining = true
    hub:quietRequest(entry.method, entry.path, entry.payload, function(body)
        hub.outboxDraining = false
        Outbox.remove(hub, entry.id)
        if hub.onOutboxSent then
            hub:onOutboxSent(entry, body)
        end
        Outbox.drain(hub)
    end, function(err, errbody)
        hub.outboxDraining = false
        entry.attempts = (entry.attempts or 0) + 1
        if permanent(err) or entry.attempts >= MAX_ATTEMPTS then
            Outbox.remove(hub, entry.id)
            if hub.onOutboxDropped then
                hub:onOutboxDropped(entry, err, errbody)
            end
            Outbox.drain(hub)
            return
        end
        Outbox.retryLater(hub, RETRY_SECONDS)
    end)
end

function Outbox.retryLater(hub, delay)
    local UIManager = require("ui/uimanager")
    if hub.outboxTimer then
        UIManager:unschedule(hub.outboxTimer)
    end
    hub.outboxTimer = function()
        hub.outboxTimer = nil
        Outbox.drain(hub)
    end
    UIManager:scheduleIn(delay, hub.outboxTimer)
end

return Outbox
