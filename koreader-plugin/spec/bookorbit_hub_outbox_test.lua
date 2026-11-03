-- Proves the hub's outbox: actions wait in settings, a newer action with the
-- same key replaces an older one, delivery goes in order, a refusal is dropped
-- and a network failure keeps the action for a later try.
package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path
local connected = true
local scheduled = {}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
    unschedule = function() end,
}
local flushes = 0
G_reader_settings = { flush = function() flushes = flushes + 1 end }
local Outbox = require("bookorbit_hub_outbox")

local sent, replies, dropped, delivered = {}, {}, {}, {}
local hub = { account = "acct", plugin = { settings = {} } }
function hub:quietRequest(method, path, payload, done, fail)
    sent[#sent + 1] = { method = method, path = path, payload = payload }
    local reply = table.remove(replies, 1) or { body = {} }
    if reply.err then fail(reply.err, reply.errbody) else done(reply.body) end
end
function hub:onOutboxSent(entry) delivered[#delivered + 1] = entry.label end
function hub:onOutboxDropped(entry, err) dropped[#dropped + 1] = entry.label .. ":" .. tostring(err) end

assert(Outbox.uuid():match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-8%x%x%x%-%x+$"), "uuids are version 4")

connected = false
Outbox.add(hub, { method = "POST", path = "/w", payload = { title = "A" }, label = "add A", key = "w:A" })
Outbox.add(hub, { method = "DELETE", path = "/w/a", label = "remove A", key = "w:A" })
Outbox.add(hub, { method = "POST", path = "/c", label = "collection", key = "c:1" })
assert(#sent == 0 and Outbox.count(hub) == 2, "Offline: nothing is sent and the newer change to A replaced the older one")
assert(Outbox.items(hub)[1].label == "remove A" and Outbox.items(hub)[2].label == "collection", "The replacement takes the newer place in line")
assert(flushes >= 3, "Every change is saved")

connected = true
replies = { { err = 404, errbody = { message = "gone" } }, { body = { ok = true } } }
Outbox.drain(hub)
assert(#sent == 2 and Outbox.count(hub) == 0, "Online: entries go in order until the outbox is empty")
assert(dropped[1] == "remove A:404", "A refused action is dropped, not retried")
assert(delivered[1] == "collection", "A delivered action is reported")

replies = { { err = "network_error" } }
Outbox.add(hub, { method = "POST", path = "/r", label = "request" })
assert(Outbox.count(hub) == 1 and Outbox.items(hub)[1].attempts == 1, "A network failure keeps the action")
assert(scheduled[#scheduled].delay == 60, "and tries again a minute later")
replies = { { body = {} } }
scheduled[#scheduled].fn()
assert(Outbox.count(hub) == 0, "The retry delivers it")

hub.account = "other"
assert(Outbox.count(hub) == 0, "Another account never sees these actions")
print("bookorbit_hub_outbox_test.lua: ok")
