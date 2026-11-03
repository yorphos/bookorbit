-- Book Roulette and Matches actions. Matching only records feedback; acquisition
-- needs an explicit Add to Library and goes through BookOrbit's request rules.
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local Toast = require("bookorbit_toast")
local Model = require("bookorbit_hub_model")
local Outbox = require("bookorbit_hub_outbox")
local NetworkMgr = require("ui/network/manager")

local R = {}
local ROOT = "/koreader/plugin/roulette"

-- Keeps at most `limit` UTF-8 characters.
local function clip(value, limit)
    local result = {}
    for char in tostring(value or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = char
        if #result >= limit then
            break
        end
    end
    return table.concat(result)
end

local function flush()
    G_reader_settings:flush()
end

-- The metadata the server stores for a decision, within its validation limits.
function R.book(book)
    local b = Model.wishlist(book)
    b.title = clip(b.title, 500)
    b.authors = {}
    for i, author in ipairs(book.authors or {}) do
        if i <= 10 then
            b.authors[#b.authors + 1] = clip(author, 255)
        end
    end
    b.description = book.description and clip(Model.plain(book.description), 8000) or nil
    b.genres = {}
    for i, genre in ipairs(book.genres or {}) do
        if i <= 30 then
            b.genres[#b.genres + 1] = clip(genre, 120)
        end
    end
    return b
end

local confirmations = {
    match = "Saved to Matches. No acquisition started.",
    pass = "Passed. This book will not be suggested again.",
    remove = "Removed from Matches. Undo is available.",
    skip = "Skipped without changing your taste profile.",
}

-- Cards decided on this Kobo, by their Roulette key, with the decision's event
-- id. Kept so a saved deck never shows a decided card again, even offline.
local MAX_DECIDED = 300
local function decidedStore(hub)
    local saved = hub.plugin.settings.hub_roulette_decided
    if type(saved) ~= "table" or saved.account ~= hub.account then
        saved = { account = hub.account, keys = {}, order = {} }
        hub.plugin.settings.hub_roulette_decided = saved
    end
    return saved
end

function R.decided(hub)
    return decidedStore(hub).keys
end

local function mark(hub, key, event_id)
    if not key then
        return
    end
    local saved = decidedStore(hub)
    if not saved.keys[key] then
        saved.order[#saved.order + 1] = key
    end
    saved.keys[key] = event_id
    while #saved.order > MAX_DECIDED do
        saved.keys[table.remove(saved.order, 1)] = nil
    end
end

local function unmark(hub, key)
    local saved = decidedStore(hub)
    saved.keys[key] = nil
    for i = #saved.order, 1, -1 do
        if saved.order[i] == key then
            table.remove(saved.order, i)
        end
    end
end

local function unmarkEvent(hub, event_id)
    for key, id in pairs(decidedStore(hub).keys) do
        if id == event_id then
            unmark(hub, key)
        end
    end
end

-- Asks for more cards once the deck runs low, merged behind the ones left.
function R.refill(hub, force)
    if hub.route.kind ~= "roulette" or hub.busy or not NetworkMgr:isConnected() then
        return
    end
    local decided, left = R.decided(hub), 0
    for _, item in ipairs((hub.state.body or {}).items or {}) do
        if not decided[item.rouletteKey or ""] then
            left = left + 1
        end
    end
    if left >= hub.ROULETTE_REFILL_BELOW and not force then
        return
    end
    local route, path = hub.route, hub:path(hub.route)
    hub:quietRequest("GET", path, nil, function(body)
        if hub.route ~= route then
            return
        end
        local merged, seen = {}, {}
        for _, list in ipairs({ (hub.state.body or {}).items or {}, body.items or {} }) do
            for _, item in ipairs(list) do
                local key = item.rouletteKey
                if key and not seen[key] and not decided[key] then
                    seen[key] = true
                    merged[#merged + 1] = item
                end
            end
        end
        local had_card = hub.state.book ~= nil
        body.items = merged
        hub.state.body = body
        require("bookorbit_list_cache").stage(hub.account .. "|hub|" .. path, body)
        if not had_card or force then
            hub:refreshView()
        else
            -- New cards only need their covers; the card on screen is unchanged.
            hub:present()
            hub.page:rebuild()
        end
        if force then
            Toast.show(#merged .. " cards saved on this Kobo. Their covers download in the background.")
        end
    end, function()
        if force then
            Toast.error("Could not reach BookOrbit for more cards.")
        end
    end)
end

-- Records a decision and moves to the next card at once. The decision is sent
-- in the background, now or when BookOrbit can be reached; its event id makes
-- a resend harmless.
function R.decide(hub, decision, book)
    if not book or not book.title then
        return
    end
    local event_id = Outbox.uuid()
    Outbox.add(hub, {
        method = "POST",
        path = ROOT .. "/decision",
        payload = {
            eventId = event_id,
            decision = decision,
            book = R.book(book),
            key = decision == "remove" and book.matchKey or nil,
        },
        label = decision .. ": " .. tostring(book.title),
        kind = "roulette",
        card = book.rouletteKey,
    })
    if decision ~= "remove" then
        mark(hub, book.rouletteKey, event_id)
    end
    hub.plugin.settings.roulette_pending = nil
    G_reader_settings:flush()
    Toast.show(confirmations[decision])
    if hub.route.kind == "detail" then
        hub:navigate({ kind = "matches" }, true)
    elseif hub.route.kind == "matches" then
        hub:load()
    else
        hub:refreshView()
        R.refill(hub)
    end
end

-- Undoes the last decision: still waiting to be sent, it is simply dropped;
-- already sent, BookOrbit undoes it.
function R.undo(hub, id)
    local queued = not id and Outbox.last(hub, "roulette")
    if queued then
        Outbox.remove(hub, queued.id)
        if queued.card then
            unmark(hub, queued.card)
        end
        G_reader_settings:flush()
        hub:refreshView()
        Toast.show("Decision undone.")
        return
    end
    local event = hub.plugin.settings.roulette_last_event
    id = id or (event and event.account == hub.account and event.id)
    if not id then
        Toast.show("No decision to undo. Open feedback history for earlier decisions.")
        return
    end
    hub:fetch("POST", ROOT .. "/undo", { eventId = id }, function()
        hub.plugin.settings.roulette_last_event = nil
        unmarkEvent(hub, id)
        G_reader_settings:flush()
        hub:load()
        Toast.show("Decision undone.")
    end)
end

function R.acquire(hub, keys)
    if #keys == 0 then
        Toast.show("Select at least one match.")
        return
    end
    hub:fetch("POST", ROOT .. "/acquire", { keys = keys }, function(body)
        local failed, requests = 0, {}
        for _, result in ipairs(body.results or {}) do
            if result.error then
                failed = failed + 1
            end
            if result.request then
                requests[#requests + 1] = result.request
            end
        end
        hub:observe(requests)
        hub.selectedMatches = {}
        hub.selectingMatches = false
        Toast.show(
            failed > 0 and (failed .. " requests need attention. Check Requests.")
                or "Requests submitted. Track them in Matches or Requests."
        )
        hub:navigate({ kind = "matches" }, true)
    end)
end

function R.tastes(hub)
    hub:fetch("GET", ROOT .. "/tastes", nil, function(body)
        local function prompt(label, key, separator)
            local dialog
            dialog = InputDialog:new {
                title = label,
                input = table.concat(body[key] or {}, separator),
                buttons = {
                    {
                        {
                            text = "Cancel",
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = "Save",
                            callback = function()
                                local values = {}
                                for value in dialog:getInputText():gmatch(separator == "; " and "[^;]+" or "[^,]+") do
                                    values[#values + 1] = value:match("^%s*(.-)%s*$")
                                end
                                body[key] = values
                                UIManager:close(dialog)
                                hub:fetch(
                                    "POST",
                                    ROOT .. "/tastes",
                                    { genres = body.genres or {}, favorites = body.favorites or {} },
                                    function()
                                        hub:load()
                                        Toast.show("Taste profile updated.")
                                    end
                                )
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end
        hub:menu("Your tastes", {
            {
                text = "Favorite genres (comma separated)",
                callback = function()
                    prompt("Favorite genres, separated by commas", "genres", ", ")
                end,
            },
            {
                text = "Favorite books (semicolon separated)",
                callback = function()
                    prompt("Favorite book titles, separated by semicolons", "favorites", "; ")
                end,
            },
        })
    end)
end

function R.history(hub, page)
    page = page or 1
    hub:fetch("GET", ROOT .. "/history?page=" .. page, nil, function(body)
        local rows = {}
        for _, item in ipairs(body) do
            local e = item.data
            rows[#rows + 1] = {
                text = (e.undone and "Undone · " or "")
                    .. tostring(e.decision)
                    .. " · "
                    .. (e.after and e.after.book.title or "Book"),
                callback = not e.undone and function()
                    R.undo(hub, e.eventId)
                end or nil,
            }
        end
        if #body == 20 then
            rows[#rows + 1] = {
                text = "Older decisions",
                callback = function()
                    R.history(hub, page + 1)
                end,
            }
        end
        if #rows == 0 then
            rows[1] = { text = "No decisions yet" }
        end
        hub:menu("Feedback history · Page " .. page, rows)
    end)
end

function R.more(hub)
    hub:menu("Roulette", {
        {
            text = "Keep cards for offline",
            callback = function()
                R.refill(hub, true)
            end,
        },
        {
            text = "Full synopsis / Why recommended?",
            callback = function()
                local b = hub.state.book or {}
                UIManager:show(TextViewer:new {
                    title = b.title or "Roulette",
                    text = (b.recommendationWhy or "") .. "\n\n" .. Model.plain(
                        b.description or "No synopsis supplied."
                    ),
                })
            end,
        },
        {
            text = "Choose or edit your tastes",
            callback = function()
                R.tastes(hub)
            end,
        },
        {
            text = "Feedback history and undo",
            callback = function()
                R.history(hub)
            end,
        },
        {
            text = "Reset Roulette data",
            callback = function()
                UIManager:show(ConfirmBox:new {
                    text = "Clear all matches, pass/skip history and your taste onboarding? Your books and acquisition requests are kept. This cannot be undone.",
                    ok_text = "Reset Roulette",
                    ok_callback = function()
                        hub:fetch("POST", ROOT .. "/reset", { confirmation = "RESET" }, function()
                            hub.plugin.settings.roulette_pending = nil
                            hub.plugin.settings.roulette_last_event = nil
                            hub.plugin.settings.hub_roulette_decided = nil
                            flush()
                            hub:load()
                        end)
                    end,
                })
            end,
        },
    })
end

function R.filters(hub)
    local function apply(key, value)
        local r = { kind = "matches", page = 1 }
        for _, k in ipairs({ "q", "genre", "sort" }) do
            r[k] = hub.route[k]
        end
        r[key] = value
        hub:navigate(r, true)
    end
    local function text(key, title)
        local dialog
        dialog = InputDialog:new {
            title = title,
            input = hub.route[key] or "",
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = "Apply",
                        callback = function()
                            local value = dialog:getInputText()
                            UIManager:close(dialog)
                            apply(key, value ~= "" and value or nil)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    hub:menu("Matches filters", {
        {
            text = "Search title or author",
            callback = function()
                text("q", "Search Matches")
            end,
        },
        {
            text = "Genre",
            callback = function()
                text("genre", "Genre (exact name)")
            end,
        },
        {
            text = "Newest matches first",
            callback = function()
                apply("sort", "recent")
            end,
        },
        {
            text = "Sort by title",
            callback = function()
                apply("sort", "title")
            end,
        },
        {
            text = "Sort by author",
            callback = function()
                apply("sort", "author")
            end,
        },
        {
            text = "Clear filters",
            callback = function()
                hub:navigate({ kind = "matches" }, true)
            end,
        },
        {
            text = "Undo a decision",
            callback = function()
                R.history(hub)
            end,
        },
    })
end

return R
