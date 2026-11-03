--[[--
Work BookOrbit does on its own: while the Kobo charges with Wi-Fi on, it
downloads requested books that became ready (and, if asked, the next book of
series being read); and it can remove downloads finished long ago. The
reader's notes and highlights stay on BookOrbit; only the file goes.

Runs when charging starts, every half hour while charging, when BookOrbit
opens and when a followed request becomes ready. Never turns Wi-Fi on.
]]
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local Trapper = require("ui/trapper")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Model = require("bookorbit_hub_model")
local Diag = require("bookorbit_hub_diag")
local Toast = require("bookorbit_toast")

local Upkeep = {}

local ROOT = "/koreader/plugin/"
local REPEAT_SECONDS = 30 * 60
local MAX_PER_RUN = 5
local FAILED_RETRY_SECONDS = 24 * 3600

local timer, running = nil, false

local function charging()
    local ok, powerd = pcall(function()
        return Device:getPowerDevice()
    end)
    if not ok or not powerd then
        return false
    end
    local is_ok, value = pcall(powerd.isCharging, powerd)
    return is_ok and value == true
end

-- A catalog that can download without a page of its own: the open hub's, or a
-- headless one.
local function catalogFor(plugin)
    local hub = plugin._bookorbit_hub
    if hub and not hub.closed and hub.catalog then
        return hub.catalog
    end
    local Catalog = require("bookorbit_catalog")
    return Catalog:new {
        api = plugin:apiOpts(true),
        settings = plugin.settings,
        path = plugin.path,
        headless = true,
        _manager = plugin,
        save_settings = function()
            G_reader_settings:flush()
        end,
        updateItems = function() end,
    }
end

-- Runs Upkeep once, delay seconds from now, replacing an earlier schedule.
function Upkeep.soon(plugin, delay)
    if timer then
        UIManager:unschedule(timer)
    end
    timer = function()
        timer = nil
        Upkeep.run(plugin)
        if charging() then
            Upkeep.soon(plugin, REPEAT_SECONDS)
        end
    end
    UIManager:scheduleIn(delay or 30, timer)
end

function Upkeep.stop()
    if timer then
        UIManager:unschedule(timer)
        timer = nil
    end
end

local function record(plugin, summary)
    plugin.settings.hub_upkeep_last = { at = os.time(), summary = summary }
    Diag.event(plugin.settings, "sync", summary)
end

-- Finished downloads older than the reader's limit: inside the BookOrbit
-- download folder only, never the book that is open.
function Upkeep.cleanup(plugin, catalog)
    local days = tonumber(Model.setting(plugin.settings, "hub_cleanup_days")) or 0
    if days <= 0 then
        return 0
    end
    local Transfer = require("bookorbit_download_transfer")
    local DocSettings = require("docsettings")
    local root = catalog:getCurrentDownloadDir()
    local open_file = plugin.ui and plugin.ui.document and plugin.ui.document.file
    local cutoff = os.date("%Y-%m-%d", os.time() - days * 86400)
    catalog:refreshOnDevice()
    local removed = 0
    for _, path in pairs(catalog.on_device or {}) do
        if path ~= open_file and Transfer.isInsideRoot(root, path) and lfs.attributes(path, "mode") == "file" then
            local ok, settings = pcall(DocSettings.open, DocSettings, path)
            local summary = ok and settings and settings:readSetting("summary") or {}
            if summary.status == "complete" and type(summary.modified) == "string" and summary.modified < cutoff then
                if os.remove(path) then
                    removed = removed + 1
                end
            end
        end
    end
    if removed > 0 then
        require("bookorbit_state_manager").invalidate()
        catalog:refreshOnDevice()
        plugin:requestSweep(false, "storage", { quiet = true })
    end
    return removed
end

local function quietGet(client, path)
    local completed, result = client:runInSubprocess(function()
        return client:requestBlocking("GET", path)
    end)
    return completed and result and result.body or nil
end

-- Library books worth having on the Kobo now: ready requests, then the next
-- volume of series being read when the reader asked for that.
local function wanted(plugin, catalog)
    local client, ids, seen = catalog.client, {}, {}
    local failed = plugin.settings.hub_upkeep_failed or {}
    local function add(id)
        id = tonumber(id)
        if
            id
            and not seen[id]
            and not catalog:onDeviceBookPath({ id = id })
            and os.time() - (failed[tostring(id)] or 0) > FAILED_RETRY_SECONDS
        then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    local ready = quietGet(client, ROOT .. "requests?page=1&filter=ready")
    for _, request in ipairs(ready and ready.items or {}) do
        add(request.bookId)
    end
    if Model.setting(plugin.settings, "hub_charging_series") then
        local reading = quietGet(client, ROOT .. "catalog/books?page=1&size=3&sort=recently_read&readStatus=reading")
        for _, book in ipairs(reading and reading.items or {}) do
            local next_up = quietGet(client, ROOT .. "hub/next?bookId=" .. tostring(book.id))
            local volume = next_up and next_up.nextInSeries
            if type(volume) == "table" then
                add(volume.bookId)
            end
        end
    end
    return ids
end

-- Downloads one book with the default file, without opening any page.
local QUIET = { close = function() end }

local function download(catalog, id, done)
    -- A held, never shown loading notice keeps these background fetches silent.
    local held = catalog.held_loading
    catalog.held_loading = QUIET
    local fetched, detail, err = pcall(catalog.fetchDeliveryBook, catalog, id)
    catalog.held_loading = held
    if not fetched then
        return done(false, detail)
    end
    if not detail then
        return done(false, err)
    end
    local file = catalog:nextDownloadFile(catalog:supportedFiles(detail))
    if not file then
        return done(false, "no_supported_file")
    end
    local CatalogUtil = require("bookorbit_catalog_util")
    local path = catalog:getLocalDownloadPath(
        CatalogUtil.safeFilenameBase(detail),
        string.lower(file.format or "bin"),
        file.devicePath
    )
    if lfs.attributes(path, "mode") then
        return done(true)
    end
    catalog:downloadFile(path, detail, file, {
        progress = function() end,
        finished = function(ok, finish_err)
            done(ok, finish_err)
        end,
    })
end

-- opts.force: run even when not charging (Diagnostics' Run now).
-- opts.report: say what happened even when nothing did.
function Upkeep.run(plugin, opts)
    opts = opts or {}
    if running or not plugin:isLoggedIn() then
        return
    end
    local ok, catalog = pcall(catalogFor, plugin)
    if not ok or not catalog then
        logger.warn("BookOrbit: upkeep could not open the catalog", catalog)
        return
    end
    local removed = Upkeep.cleanup(plugin, catalog)
    local downloads_on = Model.setting(plugin.settings, "hub_charging_downloads")
    if not downloads_on or not (opts.force or charging()) or not NetworkMgr:isConnected() then
        local summary = removed > 0 and ("Removed " .. removed .. " finished downloads")
            or (not NetworkMgr:isConnected() and "Waiting for Wi-Fi")
            or (not downloads_on and "Downloads while charging are off")
            or "Not charging"
        if removed > 0 or opts.report then
            record(plugin, summary)
            G_reader_settings:flush()
        end
        if removed > 0 then
            Toast.show(summary)
        elseif opts.report then
            Toast.show(summary)
        end
        return
    end
    running = true
    Trapper:wrap(function()
        local list_ok, ids = pcall(wanted, plugin, catalog)
        if not list_ok then
            running = false
            Diag.event(plugin.settings, "error", "Charging downloads: " .. tostring(ids))
            return
        end
        local got, failed_count, index = 0, 0, 0
        local function finish()
            running = false
            local parts = {}
            if got > 0 then
                parts[#parts + 1] = "Downloaded " .. got .. (got == 1 and " book" or " books")
            end
            if failed_count > 0 then
                parts[#parts + 1] = failed_count .. " could not be downloaded"
            end
            if removed > 0 then
                parts[#parts + 1] = "removed " .. removed .. " finished"
            end
            local summary = #parts > 0 and table.concat(parts, ", ") or "Nothing new to download"
            record(plugin, summary)
            G_reader_settings:flush()
            if got > 0 or failed_count > 0 or removed > 0 or opts.report then
                Toast.show(summary)
            end
            local hub = plugin._bookorbit_hub
            if got > 0 and hub and not hub.closed then
                hub:refreshView()
            end
        end
        local function step()
            index = index + 1
            local id = ids[index]
            if not id or index > MAX_PER_RUN then
                return finish()
            end
            Trapper:wrap(function()
                local call_ok = pcall(download, catalog, id, function(success, err)
                    if success then
                        got = got + 1
                    else
                        failed_count = failed_count + 1
                        plugin.settings.hub_upkeep_failed = plugin.settings.hub_upkeep_failed or {}
                        plugin.settings.hub_upkeep_failed[tostring(id)] = os.time()
                        Diag.event(plugin.settings, "error", "Download of book " .. id .. " failed: " .. tostring(err))
                    end
                    UIManager:nextTick(step)
                end)
                if not call_ok then
                    failed_count = failed_count + 1
                    UIManager:nextTick(step)
                end
            end)
        end
        step()
    end)
end

return Upkeep
