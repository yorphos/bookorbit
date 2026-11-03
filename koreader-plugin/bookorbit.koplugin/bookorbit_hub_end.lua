--[[--
The screen after the last page: rate the book, mark it finished, and go
straight to what is next. The next volume of its series, books that are ready
and Roulette are one tap away. Replaces KOReader's own end-of-book menu while
the option is on; everything that menu offered stays here or in KOReader.
]]
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local MenuPage = require("bookorbit_menu_page")
local UI = require("bookorbit_board_ui")
local View = require("bookorbit_hub_view")
local Theme = require("bookorbit_hub_theme")
local Model = require("bookorbit_hub_model")
local Toast = require("bookorbit_toast")
local px, ink = Theme.px, Theme.ink

local End = {}
local ROOT = "/koreader/plugin/"

local function label(value, size, w, o)
    o = o or {}
    o.s, o.w = size, w
    return UI.text(value, o)
end

local function close_koreader_menu()
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.name == "end_document" then
        UIManager:close(top)
    end
end

local function build(page, sw, sh)
    local d = page.data
    local g = Theme.geometry(sw, sh)
    local w = g.content
    local children = {
        label("You finished", Theme.small, w, { col = ink.g5 }),
        label(d.title or "this book", 26, w, { serif = true, b = true, lines = 3 }),
    }
    if d.authors and d.authors ~= "" then
        children[#children + 1] = label(d.authors, Theme.body, w, { lines = 2 })
    end
    if d.bookId then
        children[#children + 1] = View.heading("Your rating", w)
        local buttons = {}
        for i = 1, 5 do
            buttons[#buttons + 1] = { tostring(i), { kind = "rate", rating = i }, d.rating == i }
        end
        children[#children + 1] = View.actions(buttons, w)
    end
    children[#children + 1] = View.button(
        d.finished and "Marked as finished" or "Mark as finished",
        w,
        not d.finished and { kind = "finish" } or nil,
        false,
        "book-check"
    )
    children[#children + 1] = View.heading("Read next", w)
    local nxt = d.next and d.next.nextInSeries
    if d.loading then
        children[#children + 1] = label("Looking for your next book…", Theme.small, w, { col = ink.g5 })
    elseif d.error then
        children[#children + 1] = label(d.error, Theme.small, w, { col = ink.g5, lines = 2 })
    end
    if type(nxt) == "table" then
        local book = Model.book(nxt)
        book.action = { kind = "open", book = book }
        book.hint = (
            book.bookId and (page.onDevice(book.bookId) and "On this Kobo · Read now" or "In your library · Download")
        )
            or (book.requestId and "Requested")
            or "Next in the series · Request it"
        children[#children + 1] = View.card(book, w, true)
    end
    for i, request in ipairs(d.next and d.next.ready or {}) do
        if i <= 2 then
            local book = Model.book({
                bookId = request.bookId,
                title = request.title,
                authors = request.authors,
            })
            book.hint = "Ready to read"
            book.action = { kind = "open", book = book }
            children[#children + 1] = View.card(book, w, true)
        end
    end
    children[#children + 1] = View.actions({
        { "Find something new", { kind = "roulette" } },
        { "Open BookOrbit", { kind = "home" } },
    }, w)
    children[#children + 1] = View.button("Back to the book", w, { kind = "close" })
    local spaced = {}
    for i, child in ipairs(children) do
        if i > 1 then
            spaced[#spaced + 1] = UI.space(1, px(10))
        end
        spaced[#spaced + 1] = child
    end
    local content = UI.vstack({ w = w, pad = { px(24), 0, 0, 0 } }, spaced)
    return UI.overlay(sw, sh, { { widget = content, x = g.margin, y = 0 } })
end

local function request(plugin, method, path, payload, done)
    local client = require("bookorbit_api").new(plugin:apiOpts(true))
    Trapper:wrap(function()
        local completed, result = client:runInSubprocess(function()
            return client:requestBlocking(method, path, payload)
        end)
        done(completed and result and result.body, completed and result and result.err, result and result.errbody)
    end)
end

function End.open(plugin)
    if not plugin.ui or not plugin.ui.document or not plugin:isLoggedIn() then
        return
    end
    if Model.setting(plugin.settings, "hub_end_of_book") == false then
        return
    end
    local BookSheet = require("bookorbit_book_sheet")
    local ok, info = pcall(BookSheet.data, plugin)
    if not ok or type(info) ~= "table" then
        return
    end
    local summary = plugin.ui.doc_settings and plugin.ui.doc_settings:readSetting("summary") or {}
    local catalog_paths = {}
    local data = {
        title = info.title,
        authors = info.author,
        bookId = info.book_id,
        finished = summary.status == "complete",
        loading = info.book_id ~= nil and NetworkMgr:isConnected(),
        error = not info.book_id and "This book is not matched to your BookOrbit library yet."
            or (not NetworkMgr:isConnected() and "Connect to Wi-Fi to see what is next.")
            or nil,
    }
    close_koreader_menu()
    local page
    local function openHub(route)
        page:close()
        UIManager:nextTick(function()
            require("bookorbit_hub").open(plugin, false, route)
        end)
    end
    page = MenuPage.show {
        name = "bookorbit_end_of_book",
        data = data,
        build = build,
        onDevice = function(id)
            if catalog_paths[id] == nil then
                local ok_maps, maps = pcall(require("bookorbit_state_manager").onDeviceMaps)
                local path = ok_maps and maps and maps.byBookId and maps.byBookId[id]
                if type(path) == "table" then
                    path = path.file or path.path
                end
                catalog_paths[id] = type(path) == "string"
                    and require("libs/libkoreader-lfs").attributes(path, "mode") == "file"
            end
            return catalog_paths[id] == true
        end,
        on_action = function(p, action)
            if action.kind == "rate" and data.bookId then
                data.rating = action.rating
                p:refresh()
                request(
                    plugin,
                    "PUT",
                    ROOT .. "catalog/books/" .. data.bookId .. "/rating",
                    { rating = action.rating },
                    function(body, err)
                        if not body then
                            Toast.error("Could not save the rating: " .. Model.errorText("PUT", true, err))
                        end
                    end
                )
            elseif action.kind == "finish" then
                local status = plugin.ui.status
                if status and status.markBook then
                    pcall(status.markBook, status, true)
                else
                    summary.status = "complete"
                    summary.modified = os.date("%Y-%m-%d")
                    plugin.ui.doc_settings:saveSetting("summary", summary)
                end
                data.finished = true
                p:refresh()
            elseif action.kind == "open" then
                local book = action.book
                if book.bookId then
                    openHub({ kind = "detail", book = book })
                elseif book.requestId then
                    openHub({
                        kind = "request_detail",
                        id = book.requestId,
                        request = { id = book.requestId, title = book.title },
                    })
                else
                    openHub({ kind = "detail", book = book })
                end
            elseif action.kind == "roulette" then
                openHub({ kind = "roulette" })
            elseif action.kind == "home" then
                openHub({ kind = "home" })
            end
        end,
    }
    if data.loading then
        request(plugin, "GET", ROOT .. "hub/next?bookId=" .. data.bookId, nil, function(body, err, errbody)
            data.loading = false
            if body then
                data.next = body
                data.rating = body.book and body.book.rating or data.rating
            else
                data.error = Model.errorText("GET", true, err, errbody)
            end
            if not page.closed then
                page:refresh()
            end
        end)
    end
    return page
end

return End
