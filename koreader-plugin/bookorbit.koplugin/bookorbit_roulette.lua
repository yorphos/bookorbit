-- Book Roulette and Matches actions. Matching only records feedback; acquisition
-- needs an explicit Add to Library and goes through BookOrbit's request rules.
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local Toast = require("bookorbit_toast")
local Model = require("bookorbit_hub_model")

local R = {}
local ROOT = "/koreader/plugin/roulette"

local function uuid()
    local f = assert(io.open("/dev/urandom", "rb"))
    local bytes = f:read(16)
    f:close()
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

-- Sends the saved decision. Its event id makes a retry idempotent, so a decision
-- whose reply was lost is never recorded twice.
local function send(hub, pending)
    local settings = hub.plugin.settings
    hub:fetch("POST", ROOT .. "/decision", pending.payload, function(result)
        settings.roulette_pending = nil
        settings.roulette_last_event = not result.undone and { account = hub.account, id = result.eventId } or nil
        flush()
        Toast.show(
            result.undone and "This decision was already undone on another device."
                or confirmations[pending.payload.decision]
        )
        if hub.route.kind == "detail" then
            hub:navigate({ kind = "matches" }, true)
        else
            hub:load()
        end
    end)
end

function R.decide(hub, decision, book)
    if hub.busy then
        Toast.show("Please wait for the current action to finish.")
        return
    end
    if not book or not book.title then
        return
    end
    local settings = hub.plugin.settings
    local pending = settings.roulette_pending
    if pending and pending.account ~= hub.account then
        pending = nil
    end
    local same = pending and pending.payload.book.title == book.title and pending.payload.decision == decision
    if pending and not same then
        -- An earlier decision never got a reply. Let the reader retry it or let it go.
        local previous = pending.payload
        hub:menu("Unconfirmed decision: " .. tostring(previous.decision) .. " · " .. tostring(previous.book.title), {
            {
                text = "Retry it",
                callback = function()
                    send(hub, pending)
                end,
            },
            {
                text = "Discard it and continue",
                callback = function()
                    settings.roulette_pending = nil
                    flush()
                    R.decide(hub, decision, book)
                end,
            },
        })
        return
    end
    if not pending then
        pending = {
            account = hub.account,
            payload = {
                eventId = uuid(),
                decision = decision,
                book = R.book(book),
                key = decision == "remove" and book.matchKey or nil,
            },
        }
        settings.roulette_pending = pending
        flush()
    end
    send(hub, pending)
end

function R.undo(hub, id)
    local event = hub.plugin.settings.roulette_last_event
    id = id or (event and event.account == hub.account and event.id)
    if not id then
        Toast.show("No decision to undo. Open feedback history for earlier decisions.")
        return
    end
    hub:fetch("POST", ROOT .. "/undo", { eventId = id }, function()
        hub.plugin.settings.roulette_last_event = nil
        flush()
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
