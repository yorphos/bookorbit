--[[--
The last book-list pages this device loaded, kept for when the server cannot
be reached. One small file per page under the BookOrbit cache, newest kept:
saving a page writes only that page, so a page turn never rewrites the rest.
A page is keyed by the account and its exact query, so a list is only ever
shown with what that same request returned.

put() writes at once. stage() is for screens that refetch often: the page is
kept in memory, written later in one go by flush(), and not written at all
when it did not change, which spares the e-reader's flash.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local util = require("util")

local ListCache = { MAX = 60, MEMORY = 40, FLUSH_DELAY = 20 }

-- key -> { body, saved_at, etag, sig, dirty }, most recently used last in order.
local memory, order = {}, {}
local flush_scheduled = false

local function dir()
    return DataStorage:getDataDir() .. "/cache/bookorbit/lists"
end

-- account: a string naming the server and the user. query: the request's
-- parameters.
function ListCache.key(account, query)
    local parts = {}
    for k, v in pairs(query or {}) do table.insert(parts, tostring(k) .. "=" .. tostring(v)) end
    table.sort(parts)
    return tostring(account) .. "|" .. table.concat(parts, "&")
end

local function pathOf(key)
    return dir() .. "/" .. md5(key) .. ".lua"
end

-- Drops the oldest pages past MAX.
local function prune()
    local files = {}
    local ok, iter, state = pcall(lfs.dir, dir())
    if not ok then return end
    for name in iter, state do
        if name:match("%.lua$") then
            local path = dir() .. "/" .. name
            table.insert(files, { path = path, t = lfs.attributes(path, "modification") or 0 })
        end
    end
    if #files <= ListCache.MAX then return end
    table.sort(files, function(a, b) return a.t > b.t end)
    for i = ListCache.MAX + 1, #files do os.remove(files[i].path) end
end

local function touchOrder(key)
    for i = #order, 1, -1 do
        if order[i] == key then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = key
    while #order > ListCache.MEMORY do
        local oldest = table.remove(order, 1)
        local entry = memory[oldest]
        -- A page not written yet is written before it leaves memory.
        if entry and entry.dirty then ListCache.put(oldest, entry.body, entry.saved_at, entry.etag) end
        memory[oldest] = nil
    end
end

-- What a body says, for telling whether a refetch changed anything.
local function signature(body, etag)
    if etag then return "e:" .. etag end
    local ok, rapidjson = pcall(require, "rapidjson")
    if not ok then return nil end
    local encoded_ok, encoded = pcall(rapidjson.encode, body, { sort_keys = true })
    return encoded_ok and encoded and ("b:" .. md5(encoded)) or nil
end

function ListCache.put(key, body, now, etag)
    if type(body) ~= "table" then return end
    if not util.makePath(dir()) then return end
    local store = LuaSettings:open(pathOf(key))
    store:saveSetting("key", key)
    store:saveSetting("saved_at", now or os.time())
    store:saveSetting("etag", etag)
    store:saveSetting("body", body)
    store:flush()
    prune()
    local entry = memory[key]
    if entry then
        entry.body, entry.saved_at, entry.etag, entry.dirty, entry.sig = body, now or os.time(), etag, false, nil
    end
end

local function scheduleFlush()
    if flush_scheduled then return end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or not UIManager or not UIManager.scheduleIn then return end
    flush_scheduled = true
    UIManager:scheduleIn(ListCache.FLUSH_DELAY, function()
        flush_scheduled = false
        ListCache.flush()
    end)
end

-- Keeps a page in memory and writes it later. Returns true when the page
-- differs from the copy already kept, false when it is the same.
function ListCache.stage(key, body, etag, now)
    if type(body) ~= "table" then return false end
    local entry = memory[key]
    if not entry then
        entry = ListCache.load(key) and memory[key]
    end
    local sig = signature(body, etag)
    if entry then
        entry.sig = entry.sig or signature(entry.body, entry.etag)
        if sig and entry.sig == sig then
            entry.saved_at = now or os.time()
            touchOrder(key)
            return false
        end
    end
    memory[key] = { body = body, saved_at = now or os.time(), etag = etag, sig = sig, dirty = true }
    touchOrder(key)
    scheduleFlush()
    return true
end

-- The server said the page has not changed: it counts as fresh again.
function ListCache.touch(key, now)
    local entry = memory[key]
    if entry then entry.saved_at = now or os.time() end
end

-- Writes every staged page that changed since it was last written.
function ListCache.flush()
    local written = 0
    for key, entry in pairs(memory) do
        if entry.dirty then
            local ok = pcall(ListCache.put, key, entry.body, entry.saved_at, entry.etag)
            if ok then written = written + 1 end
            entry.dirty = false
        end
    end
    return written
end

-- Pages held in memory and how many still wait to be written.
function ListCache.stats()
    local held, dirty = 0, 0
    for _key, entry in pairs(memory) do
        held = held + 1
        if entry.dirty then dirty = dirty + 1 end
    end
    local files, bytes = 0, 0
    local ok, iter, state = pcall(lfs.dir, dir())
    if ok then
        for name in iter, state do
            if name:match("%.lua$") then
                files = files + 1
                local size = lfs.attributes(dir() .. "/" .. name, "size")
                bytes = bytes + (type(size) == "number" and size or 0)
            end
        end
    end
    return { memory = held, dirty = dirty, files = files, bytes = bytes }
end

-- Forgets every saved page, in memory and on disk.
function ListCache.clear()
    memory, order = {}, {}
    local ok, iter, state = pcall(lfs.dir, dir())
    if not ok then return end
    local doomed = {}
    for name in iter, state do
        if name:match("%.lua$") then doomed[#doomed + 1] = dir() .. "/" .. name end
    end
    for _i, path in ipairs(doomed) do os.remove(path) end
end

-- { body, saved_at, etag } or nil.
function ListCache.get(key)
    local entry = memory[key]
    if entry then
        touchOrder(key)
        return { body = entry.body, saved_at = entry.saved_at, etag = entry.etag }
    end
    local path = pathOf(key)
    if not lfs.attributes(path, "mode") then return nil end
    local store = LuaSettings:open(path)
    -- Two keys sharing a hash must not serve each other's page.
    if store:readSetting("key") ~= key then return nil end
    local body = store:readSetting("body")
    if type(body) ~= "table" then return nil end
    local saved = { body = body, saved_at = store:readSetting("saved_at"), etag = store:readSetting("etag") }
    return saved
end

-- Like get, and keeps the page in memory for the next look.
function ListCache.load(key)
    local saved = ListCache.get(key)
    if saved and not memory[key] then
        memory[key] = { body = saved.body, saved_at = saved.saved_at, etag = saved.etag, dirty = false }
        touchOrder(key)
    end
    return saved
end

return ListCache
