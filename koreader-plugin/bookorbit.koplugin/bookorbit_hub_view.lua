-- Native widgets shared by every BookOrbit hub screen. No web view or animation.
local UI = require("bookorbit_board_ui")
local MenuUI = require("bookorbit_menu_ui")
local Theme = require("bookorbit_hub_theme")
local Model = require("bookorbit_hub_model")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
local px, ink = Theme.px, Theme.ink
local text, row, space = UI.text, UI.hstack, UI.space
local function stack(options, items)
    local spaced = {}
    for _, item in ipairs(items) do
        if #spaced > 0 and options.gap and options.gap > 0 then
            spaced[#spaced + 1] = space(1, options.gap)
        end
        spaced[#spaced + 1] = item
    end
    return UI.vstack(options, spaced)
end
local View = {}

-- Remembers where its child was painted, under a key, so a later change inside
-- it (a cover that arrived, a notice that cleared) can refresh only that spot.
local Slot = WidgetContainer:extend {
    rects = nil,
    key = nil,
}

function Slot:getSize()
    return self[1]:getSize()
end

function Slot:paintTo(bb, x, y)
    local size = self[1]:getSize()
    if self.rects and self.key then
        self.rects[self.key] = Geom:new { x = x, y = y, w = size.w, h = size.h }
    end
    self[1]:paintTo(bb, x, y)
end

-- Where the covers of the screen being built were painted, by cover key.
local cover_rects = nil

local function label(value, size, width, options)
    options = options or {}
    options.s = size
    options.w = width
    return text(value, options)
end

function View.button(title, width, action, primary, icon_name)
    local h, border = px(Theme.button), math.max(1, px(1))
    local parts = { UI.flex(0) }
    if icon_name then
        parts[#parts + 1] = UI.icon(icon_name, px(20), { col = primary and "white" or "black" })
        parts[#parts + 1] = space(px(7), 1)
    end
    parts[#parts + 1] = label(
        title,
        Theme.body,
        width - px(icon_name and 48 or 20),
        { b = primary, align = "center", col = primary and ink.white or (action and ink.black or ink.g8) }
    )
    parts[#parts + 1] = UI.flex(0)
    local widget = UI.box({
        w = width,
        h = h,
        border = border,
        border_col = ink.black,
        radius = px(5),
        bg = primary and ink.black or ink.white,
    }, row({ w = width - 2 * border, h = h - 2 * border }, parts))
    return action and UI.hit(widget, action) or widget
end

local function iconButton(name, action)
    local s = px(44)
    return UI.hit(row({ w = s, h = s }, { UI.flex(0), UI.icon(name, px(23)), UI.flex(0) }), action)
end

local function heading(title, w, action, subtitle)
    local parts = { label(title, Theme.heading, w - (action and px(86) or 0), { serif = true, b = true }) }
    if action then
        parts[#parts + 1] = UI.hit(
            row({ w = px(86), h = px(36) }, { label("See all ›", Theme.small, px(86), { align = "right" }) }),
            action
        )
    end
    local line = row({ w = w, h = px(36) }, parts)
    if subtitle and subtitle ~= "" then
        return stack({ w = w, gap = px(2) }, { line, label(subtitle, Theme.small, w, { col = ink.g5 }) })
    end
    return line
end

function View.cover(book, w, h)
    local widget = UI.cover(
        book,
        w,
        h,
        { path = book.coverPath, border = math.max(1, px(0.5)), border_col = ink.g8, valign = "center" }
    )
    if cover_rects and book.hub_cover_key and not book.coverPath then
        return Slot:new { rects = cover_rects, key = book.hub_cover_key, widget }
    end
    return widget
end

-- The status line under a page's heading. It always takes its line, even
-- empty, so the page below never moves when it changes and it can repaint alone.
-- fallback: a subtitle shown on the same line when there is nothing to report.
local function notice(state, w, list, fallback)
    local body = state.body or {}
    local text
    if state.loading then
        text = state.cached and "Saved copy · Checking for changes…" or "Loading…"
    elseif state.error then
        text = state.error
    elseif state.cached then
        text = list and "Saved results" or "Saved on this Kobo · Refresh for the latest status"
    end
    if list and (body.partial or body.truncated) then
        text = (text and (text .. " · ") or "") .. "Some sources unavailable · Refresh or refine"
    end
    state.noticeRect = nil
    return Slot:new {
        rects = state,
        key = "noticeRect",
        label(text or fallback or " ", Theme.small, w, { col = ink.g5, lines = 1 }),
    }
end

function View.card(book, w, compact)
    local h = px(compact and 72 or Theme.row)
    local padding, gap = px(8), px(12)
    local border = math.max(1, px(0.6))
    local cw, ch = px(compact and 38 or 63), h - 2 * padding - 2 * border
    local tw = w - 2 * border - 2 * padding - cw - 2 * gap - px(15)
    local details = {
        label(
            book.displayTitle or book.title or "Untitled",
            compact and 17 or 19,
            tw,
            { serif = true, b = true, lines = compact and 1 or 2 }
        ),
        label(table.concat(book.authors or {}, ", "), Theme.small, tw, { col = ink.g5 }),
    }
    local meta = not compact and Model.meta(book) or ""
    if meta ~= "" then
        details[#details + 1] = label(meta, 12, tw, { col = ink.g5 })
    end
    local status = book.hint or (book.request and Model.stage(book.request) or Model.status(book))
    local percent = Model.percent(
        book.request and book.request.status == "downloading" and book.request.progressPercent
            or (not book.request and book.progressPercentage)
    )
    if percent then
        status = status .. string.format(" · %d%%", percent)
    end
    details[#details + 1] = label(status, Theme.small, tw, { b = true })
    local content = stack({ w = w - 2 * border, h = h - 2 * border, pad = padding }, {
        row({ w = w - 2 * border - 2 * padding, h = ch, gap = gap }, {
            View.cover(book, cw, ch),
            stack({ w = tw, gap = px(2) }, details),
            UI.icon("chevron-right", px(15)),
        }),
    })
    return UI.hit(
        UI.box({ w = w, h = h, border = border, border_col = ink.g8, radius = px(5), bg = ink.white }, content),
        book.action or { kind = "book", book = book }
    )
end

function View.listCard(book, w)
    local h, gap, pad = px(Theme.listRow), px(10), px(5)
    local cw, ch = px(36), h - pad * 2
    local tw = w - cw - 2 * pad - 3 * gap - px(12) - 2 * math.max(1, px(0.5))
    local status = book.hint or (book.request and Model.stage(book.request) or Model.status(book))
    local meta = Model.meta(book)
    local lines = stack({ w = tw, gap = px(1) }, {
        label(book.displayTitle or book.title, 16, tw, { serif = true, b = true }),
        label(table.concat(book.authors or {}, ", "), 12, tw, { col = ink.g5 }),
        label(status .. (meta ~= "" and (" · " .. meta) or ""), 11, tw, { col = ink.g5 }),
    })
    return UI.hit(
        UI.box(
            { w = w, h = h, border = math.max(1, px(0.5)), border_col = ink.g8, bg = ink.white },
            row(
                { w = w - 2, h = h - 2, gap = gap },
                { space(pad, 1), View.cover(book, cw, ch), lines, UI.icon("chevron-right", px(12)) }
            )
        ),
        book.action or { kind = "book", book = book }
    )
end

local listKinds = {
    roulette = true,
    matches = true,
    discover = true,
    search = true,
    browse = true,
    books = true,
    requests = true,
    releases = true,
    series_list = true,
    author_list = true,
    genre_list = true,
    wishlist = true,
    collections = true,
    series = true,
    social = true,
}
function View.isList(kind)
    return listKinds[kind] == true
end

local function shelf(books, w, count, compact)
    count = math.min(count or 4, #books)
    if count == 0 then
        return label("Explore your library or discover something new.", Theme.body, w, { lines = 2 })
    end
    local gap = px(12)
    local cw = math.floor((w - (count - 1) * gap) / count)
    local ch = math.min(math.floor(cw * 1.45), px(compact and 124 or 148))
    local cards = {}
    for i = 1, count do
        local book = books[i]
        cards[#cards + 1] = UI.hit(
            stack({ w = cw, gap = px(4) }, {
                View.cover(book, cw, ch),
                label(book.title, 14, cw, { serif = true, b = true, lines = 2 }),
                label(table.concat(book.authors or {}, ", "), 11, cw, { col = ink.g5 }),
            }),
            { kind = "book", book = book }
        )
    end
    return row({ w = w, gap = gap, valign = "top" }, cards)
end

local function actions(buttons, w)
    local children, gap = {}, px(8)
    local width = math.floor((w - gap * (#buttons - 1)) / #buttons)
    for _, b in ipairs(buttons) do
        children[#children + 1] = View.button(b[1], width, b[2], b[3], b[4])
    end
    return row({ w = w, gap = gap }, children)
end

local function footer(g, tab)
    local tabs = {
        { "home", "Home", "house" },
        { "discover", "Discover", "compass" },
        { "books", "My Books", "library" },
        { "requests", "Requests", "list" },
    }
    local parts, width = {}, math.floor(g.w / 4)
    for _, item in ipairs(tabs) do
        local selected = item[1] == tab
        parts[#parts + 1] = UI.hit(
            stack({ w = width, h = g.footer - px(1), align = "center", gap = px(3), pad = { px(6), 0, px(6), 0 } }, {
                UI.icon(item[3], px(24), { sw = selected and 2.7 or 1.8 }),
                label(item[2], Theme.small, width, { align = "center", b = selected }),
                selected and UI.rect(px(62), px(3), ink.black, px(1)) or space(1, px(3)),
            }),
            { kind = "tab", tab = item[1] }
        )
    end
    return stack(
        { w = g.w },
        { UI.rect(g.w, math.max(1, px(0.5)), ink.g8), row({ w = g.w, h = g.footer - px(1) }, parts) }
    )
end

local function header(g, state)
    local brand_width = g.content - px(state.updateVersion and 176 or 132)
    local brand = label("BookOrbit", Theme.brand, brand_width, { serif = true, b = true })
    return stack({ w = g.w, pad = { px(8), g.margin, px(8), g.margin }, gap = px(7) }, {
        row({ w = g.content, h = px(44) }, {
            iconButton("chevron-left", { kind = "back" }),
            UI.hit(brand, { kind = "tab", tab = "home" }),
            iconButton("refresh-cw", { kind = "refresh" }),
            state.updateVersion and iconButton("download", { kind = "update" }) or space(0, 1),
            iconButton("sliders-horizontal", { kind = "settings" }),
        }),
        View.button(
            state.route.q or "Search books, authors, series, ISBN…",
            g.content,
            { kind = "search" },
            false,
            "search"
        ),
    })
end

local function listBody(state, g)
    local body, r, w = state.body or {}, state.route, g.content
    local children = { heading(state.title or "Books", w) }
    if r.kind == "search" or r.kind == "browse" then
        local scopes = { "all", "library", "requestable" }
        local selected = r.scope == "library" and 2 or r.scope == "requestable" and 3 or 1
        children[#children + 1] = MenuUI.segmented(w, { "All", "In Library", "Requestable" }, selected, function(i)
            return { kind = "scope", scope = scopes[i] }
        end)
    elseif r.kind == "requests" then
        local filters = { "all", "pending", "processing", "ready", "failed" }
        local selected = 1
        for i, value in ipairs(filters) do
            if r.filter == value then
                selected = i
            end
        end
        children[#children + 1] = MenuUI.segmented(
            w,
            { "All", "Pending", "Active", "Ready", "Failed" },
            selected,
            function(i)
                return { kind = "request_filter", filter = filters[i] }
            end
        )
    elseif r.kind == "books" then
        local filters = { "recent", "local", "reading" }
        local selected = r.filter == "local" and 2 or r.filter == "reading" and 3 or 1
        children[#children + 1] = MenuUI.segmented(w, { "Library", "On Device", "Reading" }, selected, function(i)
            return { kind = "books_filter", filter = filters[i] }
        end)
    end
    if r.kind == "discover" or r.kind == "genre_list" then
        children[#children + 1] = actions({
            { "Roulette", { kind = "roulette" } },
            { "Matches", { kind = "matches" } },
            { "Genres", { kind = "genre_list" } },
            { "More", { kind = "discover_more" } },
        }, w)
    end
    if r.kind == "matches" then
        children[#children + 1] = actions({
            { "Filters", { kind = "match_filters" } },
            { state.selectingMatches and "Done selecting" or "Select", { kind = "match_select" } },
            {
                "Add (" .. tostring(state.selectedCount or 0) .. ")",
                (state.selectedCount or 0) > 0 and { kind = "match_acquire" } or nil,
            },
        }, w)
    end
    if r.kind == "search" or r.kind == "browse" or r.kind == "books" then
        children[#children + 1] =
            View.button(state.filterLabel or "Filters & sort", w, { kind = "filters" }, false, "sliders-horizontal")
    end
    if r.kind == "social" then
        children[#children + 1] = View.button(
            body.share and "Stop sharing my reading" or "Share my reading with other readers",
            w,
            { kind = "share_toggle" },
            not body.share
        )
        if not body.share then
            state.empty = "Nothing to show until you share."
            children[#children + 1] = label(
                "Readers on this BookOrbit who share see what each other are reading, finished and recommend. Only books you may open are listed. Turn it off any time.",
                Theme.small,
                w,
                { lines = 4, col = ink.g5 }
            )
        elseif body.people then
            state.subtitle = #body.people == 0 and "No other reader shares yet"
                or (#body.people .. (#body.people == 1 and " reader shares" or " readers share") .. " with you")
        end
    end
    if r.kind == "collections" then
        children[#children + 1] = View.button("New collection", w, { kind = "create_collection" }, false, "plus")
    end
    children[#children + 1] = notice(state, w, true, state.subtitle)
    local books = state.visible or {}
    for _, book in ipairs(books) do
        children[#children + 1] = View.listCard(book, w)
    end
    if #books == 0 then
        children[#children + 1] =
            label(state.empty or "No books here yet. Try search or another filter.", Theme.body, w, { lines = 3 })
    end
    local pager_width = math.floor((w - px(16)) / 3)
    local pager = row({ w = w, gap = px(8), h = px(Theme.button) }, {
        View.button("‹ Previous", pager_width, state.previous and { kind = "page", delta = -1 } or nil),
        label(state.pageLabel or "Page 1", Theme.small, pager_width, { align = "center", b = true }),
        View.button("Next ›", pager_width, state.next and { kind = "page", delta = 1 } or nil),
    })
    local content = stack({ w = w, gap = px(7) }, children)
    local content_h = content:getSize().h
    state.listContentHeight = content_h
    return stack({ w = w }, { content, space(1, math.max(0, g.body - content_h - pager:getSize().h)), pager })
end

-- Five steps, each a bar over its name: done and current steps are solid,
-- later ones a thin grey line. The current name is bold, and marked when the
-- request is waiting on an administrator.
local function stepper(request, w)
    local reached, waiting = Model.step(request)
    if not reached then
        return nil
    end
    local count, gap = #Model.STEPS, px(6)
    local cell = math.floor((w - gap * (count - 1)) / count)
    local cells = {}
    for i, name in ipairs(Model.STEPS) do
        local done = i <= reached
        local current = i == reached
        local bar = done and UI.rect(cell, px(6), ink.black, px(1))
            or stack({ w = cell }, { space(1, px(2)), UI.rect(cell, px(2), ink.g8), space(1, px(2)) })
        local caption = current and waiting and (name .. " ·  waiting") or name
        cells[#cells + 1] = stack({ w = cell, gap = px(5) }, {
            bar,
            label(
                caption,
                Theme.small,
                cell,
                { align = "center", b = current, col = done and ink.black or ink.g5, lines = 2 }
            ),
        })
    end
    return row({ w = w, gap = gap, valign = "top" }, cells)
end

local function requestDetail(state, g)
    local b, r, w = state.book or {}, state.body or {}, g.content
    local children = { heading("Book Request", w), View.card(b, w), heading(Model.stage(r), w) }
    children[#children + 1] = stepper(r, w)
    local percent = r.status == "downloading" and Model.percent(r.progressPercent)
    if percent then
        children[#children + 1] = UI.bar(w, px(8), percent)
        children[#children + 1] = label(string.format("%d%% reported by the downloader", percent), Theme.small, w)
    end
    if r.status == "pending" then
        children[#children + 1] = label(
            "Waiting for administrator approval. BookOrbit will use your configured sources after approval.",
            Theme.body,
            w,
            { lines = 3 }
        )
    elseif r.status == "failed" then
        children[#children + 1] = label(
            "Acquisition failed. Use Change file to choose another release, or retry if permitted.",
            Theme.body,
            w,
            { lines = 3 }
        )
    elseif r.status == "needs_review" then
        children[#children + 1] = label(
            r.languageNeedsReview and "The downloaded language did not match. The import is held for review."
                or "The import needs administrator review.",
            Theme.body,
            w,
            { lines = 3 }
        )
    end
    if r.status == "available" and r.bookId and not r.replacementBookId then
        children[#children + 1] = View.button(
            b.localPath and "Read now" or "Download and read",
            w,
            { kind = "primary", book = b },
            true,
            "book-open"
        )
    end
    if r.status == "available" and r.replacementBookId then
        children[#children + 1] = View.button(
            "Download replacement",
            w,
            { kind = "swap", bookId = r.bookId, previousBookId = r.replacementBookId }
        )
    end
    children[#children + 1] = View.button("Refresh status", w, { kind = "refresh" }, false, "refresh-cw")
    if r.canChooseRelease then
        children[#children + 1] = View.button("Change file", w, { kind = "releases" })
    end
    if r.canRetry then
        children[#children + 1] = View.button("Retry automatic acquisition", w, { kind = "retry" })
    end
    if r.canDiscardHeld then
        children[#children + 1] = View.button("Discard held file and try another release", w, { kind = "discard_held" })
    end
    if r.canReplace then
        children[#children + 1] = View.button("Change file", w, { kind = "replace_request" })
    end
    if r.canCancel then
        children[#children + 1] = View.button("Cancel request", w, { kind = "cancel_request" })
    end
    children[#children + 1] = label(
        "Status updates by itself while BookOrbit is open, more slowly the longer nothing changes. When the book is ready, BookOrbit syncs it and tells you.",
        Theme.small,
        w,
        { lines = 3, col = ink.g5 }
    )
    return stack({ w = w, gap = px(12) }, children)
end

local function home(state, g)
    local body, w = state.body or {}, g.content
    local children = {}
    if state.homeStats then
        children[#children + 1] = UI.hit(
            row({ w = w, h = px(26), gap = px(6) }, {
                UI.icon("flame", px(16)),
                label(state.homeStats, Theme.small, w - px(22), { b = true }),
            }),
            { kind = "stats" }
        )
    end
    for _, item in ipairs({
        heading(
            "For You",
            w,
            { kind = "tab", tab = "discover" },
            body.recommendationReason or "Discover your next book"
        ),
        shelf(state.recommendations or {}, w, 4, true),
        heading("Continue Reading", w, { kind = "books_filter", filter = "reading" }),
    }) do
        children[#children + 1] = item
    end
    if state.continueReading and state.continueReading[1] then
        children[#children + 1] = View.card(state.continueReading[1], w, true)
    else
        children[#children + 1] = label("Your next chapter starts in My Books.", Theme.small, w)
    end
    if state.ready and #state.ready > 0 then
        children[#children + 1] = heading("Ready to Read", w, { kind = "request_filter", filter = "ready" })
        children[#children + 1] = shelf(state.ready, w, 4, true)
    end
    children[#children + 1] = heading("Recent Requests", w, { kind = "tab", tab = "requests" })
    if state.requests and state.requests[1] then
        children[#children + 1] = View.card(state.requests[1], w, true)
    else
        children[#children + 1] = label(
            body.requestsUnavailable and "Requests unavailable. Refresh to try again." or "No recent requests.",
            Theme.small,
            w
        )
    end
    children[#children + 1] = actions({
        { "Stats", { kind = "stats" } },
        { "Friends", { kind = "social" } },
        { "Series", { kind = "series_list" } },
        { "Downloads", { kind = "books_filter", filter = "local" } },
    }, w)
    if state.canResume then
        table.insert(children, 1, View.button("Resume Reading", w, { kind = "resume_reading" }, true))
    end
    return stack({ w = w, gap = px(7) }, children)
end

local function detail(state, g)
    local b, w = state.book or {}, g.content
    local cw, gap = math.floor(w * 0.29), px(16)
    local tw = w - cw - gap
    local metadata = Model.meta(b)
    if b.pageCount then
        metadata = metadata .. " · " .. b.pageCount .. " pages"
    end
    local info = {
        label(b.title, 25, tw, { serif = true, b = true, lines = 3 }),
        label(table.concat(b.authors or {}, ", "), 17, tw, { serif = true, lines = 2 }),
        label(metadata, Theme.small, tw, { lines = 2, col = ink.g5 }),
        label(Model.status(b), Theme.small, tw, { b = true }),
    }
    if b.rating then
        info[#info + 1] = label("Your rating: " .. tostring(b.rating) .. " / 5", Theme.small, tw)
    end
    if b.communityRating then
        info[#info + 1] = label(
            string.format("%.1f / 5", b.communityRating)
                .. (b.communityRatingCount and (" · " .. b.communityRatingCount .. " ratings") or ""),
            Theme.small,
            tw
        )
    end
    local children = {
        row(
            { w = w, gap = gap, valign = "top" },
            { View.cover(b, cw, math.floor(cw * 1.45)), stack({ w = tw, gap = px(6) }, info) }
        ),
    }
    children[#children + 1] = actions({
        {
            b.localPath and "Read"
                or b.bookId and "Download"
                or b.requestId and "View request"
                or b.matchKey and "Add to Library"
                or "Request book",
            { kind = "primary", book = b },
            true,
        },
        { b.wishlistKey and "Remove wishlist" or "Add to Wishlist", { kind = "save_wishlist", book = b } },
    }, w)
    if b.matchKey then
        children[#children + 1] = View.button("Remove from Matches", w, { kind = "match_remove", book = b })
    end
    children[#children + 1] = label(
        Model.plain(b.description) ~= "" and Model.plain(b.description) or "No description supplied by this catalog.",
        Theme.body,
        w,
        { serif = true, lines = 5 }
    )
    children[#children + 1] = actions({
        { "Description & editions", { kind = "editions", book = b } },
        { b.bookId and "Collections / files" or "Request / sources", { kind = "book_options", book = b } },
    }, w)
    children[#children + 1] = heading("Explore related books", w)
    children[#children + 1] = actions({
        { "By this author", { kind = "author", q = b.authors and b.authors[1] } },
        {
            b.seriesName and "In this series" or "Related genres",
            { kind = b.seriesName and "series" or "genres", book = b, q = b.seriesName },
        },
    }, w)
    children[#children + 1] =
        View.button("More like this in Roulette", w, { kind = "more_like_this", book = b }, false, "shuffle")
    if state.related and #state.related > 0 then
        children[#children + 1] = shelf(state.related, w, 4)
    end
    return stack({ w = w, gap = px(12) }, children)
end

local function series(state, g)
    local body, w = state.body or {}, g.content
    local a = Model.seriesActions(body)
    local children = {
        heading(state.route.q or "Series", w),
        label(
            #(body.items or {})
                .. " known records · "
                .. (body.orderingComplete and "Numbered reading order" or "Some volume positions are unknown"),
            Theme.small,
            w,
            { lines = 2, col = ink.g5 }
        ),
        actions({
            { "Continue series", a.continue and { kind = "book", book = a.continue } or nil },
            { "Request missing", a.complete and #a.missing > 0 and { kind = "request_series" } or nil },
        }, w),
    }
    for _, b in ipairs(state.visible or {}) do
        children[#children + 1] = View.listCard(b, w)
    end
    children[#children + 1] = label(state.pageLabel or "Page 1", Theme.small, w, { align = "center", b = true })
    children[#children + 1] = actions({
        { "‹ Previous", state.previous and { kind = "page", delta = -1 } or nil },
        { "Download in order", #a.owned > 0 and { kind = "download_series" } or nil },
        { "Next ›", state.next and { kind = "page", delta = 1 } or nil },
    }, w)
    if not body.orderingComplete then
        children[#children + 1] = label(
            "Bulk actions use confirmed volume numbers only. Choose unnumbered editions individually.",
            Theme.small,
            w,
            { lines = 2, col = ink.g5 }
        )
    end
    return stack({ w = w, gap = px(10) }, children)
end

local function roulette(state, g)
    local w, b = g.content, state.book
    local remaining = state.remaining and state.remaining > 1 and (tostring(state.remaining) .. " cards ready") or nil
    local children = { heading(state.title or "Book Roulette", w, nil, remaining), notice(state, w, true) }
    if not state.body.onboarded then
        children[#children + 1] = View.button("Choose your favorite books & genres", w, { kind = "roulette_tastes" })
    end
    if b then
        local ch = math.min(px(130), math.floor(g.body * 0.24))
        local cw = math.floor(ch / 1.45)
        local tw = w - cw - px(14)
        children[#children + 1] = row({ w = w, gap = px(14), valign = "top" }, {
            View.cover(b, cw, ch),
            stack({ w = tw, gap = px(5) }, {
                label(b.title, 22, tw, { serif = true, b = true, lines = 3 }),
                label(table.concat(b.authors or {}, ", "), 15, tw, { lines = 2 }),
                label(table.concat(b.genres or {}, " · "), Theme.small, tw, { lines = 2, col = ink.g5 }),
            }),
        })
        children[#children + 1] = label(
            Model.plain(b.description or "No synopsis supplied. Open More for available details."),
            Theme.body,
            w,
            { serif = true, lines = state.body.onboarded and 4 or 2 }
        )
        children[#children + 1] =
            label(b.recommendationWhy or "An exploratory suggestion", Theme.small, w, { lines = 2, b = true })
    else
        children[#children + 1] = label(
            state.loading and "Finding books…"
                or state.error
                or "No new picks right now. Change your tastes, undo a decision, or refresh later.",
            Theme.body,
            w,
            { lines = 3 }
        )
    end
    local controls = stack({ w = w, gap = px(8) }, {
        actions({
            { "Pass", b and { kind = "roulette_decide", decision = "pass", book = b } },
            { "Match", b and { kind = "roulette_decide", decision = "match", book = b }, true },
            { "Skip", b and { kind = "roulette_decide", decision = "skip", book = b } },
        }, w),
        actions({
            { "Undo", { kind = "roulette_undo" } },
            { "Matches", { kind = "matches" } },
            {
                "More",
                { kind = "roulette_more" },
            },
        }, w),
    })
    local content = stack({ w = w, gap = px(7) }, children)
    return stack(
        { w = w },
        { content, space(1, math.max(0, g.body - content:getSize().h - controls:getSize().h)), controls }
    )
end

local function settings(state, g)
    local w = g.content
    return stack({ w = w, gap = px(14) }, {
        heading("Settings", w, nil, "BookOrbit " .. (state.version or "") .. " · " .. (state.username or "")),
        heading("Reading & device", w),
        actions({
            { "Display & text", { kind = "setting", view = "home" } },
            { "Startup & shortcuts", { kind = "setting", view = "opening" } },
        }, w),
        actions({ { "Downloads", { kind = "setting", view = "downloads" } }, { "Storage", { kind = "storage" } } }, w),
        heading("Account & sync", w),
        actions({
            { "Account", { kind = "setting", view = "account" } },
            {
                "Sync preferences",
                { kind = "setting", view = "sync" },
            },
        }, w),
        actions({ { "Sync now", { kind = "sync_now" } }, { "Sync status", { kind = "sync_status" } } }, w),
        heading("BookOrbit hub", w),
        actions({ { "Reading stats", { kind = "stats" } }, { "Friends", { kind = "social" } } }, w),
        actions({ { "Hub options", { kind = "hub_settings" } }, { "Diagnostics", { kind = "diagnostics" } } }, w),
        heading("Application", w),
        View.button(
            state.updateVersion and ("Update to " .. state.updateVersion) or "About & updates",
            w,
            { kind = "setting", view = "about" },
            state.updateVersion ~= nil
        ),
        actions({ { "Classic catalog", { kind = "classic" } }, { "KOReader files", { kind = "close_hub" } } }, w),
    })
end

-- Reading time per day as a small bar chart, oldest on the left.
local function dayBars(minutes, w, h)
    local count = #minutes
    if count == 0 then
        return nil
    end
    local gap = px(4)
    local bw = math.floor((w - gap * (count - 1)) / count)
    local most = 1
    for _, m in ipairs(minutes) do
        most = math.max(most, tonumber(m) or 0)
    end
    local bars = {}
    for _, m in ipairs(minutes) do
        local bh = math.floor(h * (tonumber(m) or 0) / most + 0.5)
        bars[#bars + 1] = bh > 0 and UI.rect(bw, bh, ink.black, px(1)) or UI.rect(bw, math.max(1, px(1)), ink.g8)
    end
    return row({ w = w, h = h, gap = gap, valign = "bottom" }, bars)
end

local function stats(state, g)
    local body, w = state.body or {}, g.content
    local minutes = body.minutes or {}
    local goal, streak = body.goal or {}, body.streak or {}
    local children = { heading("Reading stats", w) }
    if not body.minutes then
        children[#children + 1] = label(
            state.loading and "Loading your reading…" or state.error or "Refresh to load your reading stats.",
            Theme.body,
            w,
            { lines = 3 }
        )
        return stack({ w = w, gap = px(10) }, children)
    end
    local half = math.floor((w - px(8)) / 2)
    local function figure(value, caption)
        return stack({ w = half, gap = px(2) }, {
            label(value, 22, half, { serif = true, b = true }),
            label(caption, Theme.small, half, { col = ink.g5 }),
        })
    end
    children[#children + 1] = row({ w = w, gap = px(8), valign = "top" }, {
        figure(Model.minutes(minutes.today), "Today"),
        figure(Model.minutes(minutes.week), "Last 7 days"),
    })
    children[#children + 1] = row({ w = w, gap = px(8), valign = "top" }, {
        figure(Model.minutes(minutes.month), "Last 30 days"),
        figure(Model.minutes(minutes.year), "Last 12 months"),
    })
    children[#children + 1] = heading("Last two weeks", w)
    children[#children + 1] = dayBars(body.lastFourteenDays or {}, w, px(70))
    children[#children + 1] = heading("Streak", w)
    children[#children + 1] = label(
        tostring(streak.current or 0)
            .. "-day streak · longest "
            .. tostring(streak.longest or 0)
            .. " days · "
            .. tostring(body.readingDaysThisYear or 0)
            .. " reading days this year",
        Theme.body,
        w,
        { lines = 2 }
    )
    children[#children + 1] = heading("Goal for " .. tostring(goal.year or ""), w)
    if tonumber(goal.goal) and goal.goal > 0 then
        children[#children + 1] = UI.bar(w, px(8), math.min(100, (goal.done or 0) * 100 / goal.goal))
        children[#children + 1] =
            label(tostring(goal.done or 0) .. " of " .. tostring(goal.goal) .. " books", Theme.small, w, { b = true })
    else
        children[#children + 1] = label(
            tostring(goal.done or 0) .. " books finished. Set a yearly goal on the BookOrbit dashboard.",
            Theme.small,
            w,
            { lines = 2 }
        )
    end
    children[#children + 1] = actions({
        { "Finished: " .. tostring(body.finishedTotal or 0), { kind = "finished_books" } },
        { "Reading: " .. tostring(body.readingNow or 0), { kind = "books_filter", filter = "reading" } },
    }, w)
    if state.finished and #state.finished > 0 then
        children[#children + 1] = heading("Recently finished", w)
        children[#children + 1] = shelf(state.finished, w, 4, true)
    end
    return stack({ w = w, gap = px(10) }, children)
end

local function lines(items, w, empty)
    local out = {}
    for _, text in ipairs(items or {}) do
        out[#out + 1] = label(text, Theme.small, w, { lines = 2 })
    end
    if #out == 0 then
        out[1] = label(empty, Theme.small, w, { col = ink.g5 })
    end
    return stack({ w = w, gap = px(4) }, out)
end

local function diagnostics(state, g)
    local d, w = state.diag or {}, g.content
    local cache = d.cache or {}
    local children = {
        heading("Diagnostics", w, nil, "BookOrbit " .. tostring(d.version or "") .. " · " .. tostring(d.user or "")),
        label(
            (d.connected and "Connected" or "Offline")
                .. " · "
                .. tostring(cache.files or 0)
                .. " saved pages ("
                .. Model.bytes(cache.bytes)
                .. ", "
                .. tostring(cache.dirty or 0)
                .. " waiting to be written) · "
                .. tostring(d.covers or 0)
                .. " covers ("
                .. Model.bytes(d.coverBytes)
                .. ")",
            Theme.small,
            w,
            { lines = 3 }
        ),
        heading("Saved actions", w),
        lines(d.outbox, w, "Nothing waiting to be sent."),
    }
    if d.outbox and #d.outbox > 0 then
        children[#children + 1] = actions({
            { "Send now", { kind = "outbox_send" } },
            { "Discard all", { kind = "outbox_discard" } },
        }, w)
    end
    children[#children + 1] = heading("Followed requests", w)
    children[#children + 1] = lines(d.watched, w, "No request is being followed.")
    children[#children + 1] = heading("Downloads and cleanup", w)
    children[#children + 1] = label("Last run: " .. tostring(d.upkeep), Theme.small, w, { lines = 2 })
    children[#children + 1] = heading("Request timing", w)
    children[#children + 1] = lines(d.timings, w, "No requests timed since BookOrbit opened.")
    children[#children + 1] = heading("Recent events", w)
    children[#children + 1] = lines(d.events, w, "Nothing recorded yet.")
    children[#children + 1] = actions({
        { "Run downloads now", { kind = "upkeep_now" } },
        { "Clear saved pages", { kind = "clear_cache" } },
    }, w)
    return stack({ w = w, gap = px(10) }, children)
end

local function hubSettings(state, g)
    local w = g.content
    local children = { heading("Hub options", w, nil, "Changes apply at once") }
    for _, option in ipairs(Model.OPTIONS) do
        children[#children + 1] = stack({ w = w, gap = px(4) }, {
            label(option.label, Theme.small, w, { lines = 2, col = ink.g5 }),
            View.button(Model.settingLabel(state.settings, option.key), w, { kind = "hub_option", key = option.key }),
        })
    end
    children[#children + 1] = label(
        "Downloads while charging use your Wi-Fi when it is already on. Removing finished downloads keeps your notes and highlights, which BookOrbit stores. Error reports contain the error text and plugin version only.",
        Theme.small,
        w,
        { lines = 5, col = ink.g5 }
    )
    return stack({ w = w, gap = px(10) }, children)
end

function View.build(state, w, h)
    local g = Theme.geometry(w, h)
    -- Reserve the native scrollbar's width. It appears only when font scaling
    -- or a long page needs another screenful; there is no animated scrolling.
    g.content = g.content - px(10)
    local hit_start = UI.hitMark()
    local kind = state.route.kind
    state.coverRects = {}
    cover_rects = state.coverRects
    local body
    if kind == "roulette" then
        body = roulette(state, g)
    elseif kind == "home" then
        body = home(state, g)
    elseif kind == "settings" then
        body = settings(state, g)
    elseif kind == "discover" then
        body = listBody(state, g)
    elseif kind == "detail" then
        body = detail(state, g)
    elseif kind == "request_detail" then
        body = requestDetail(state, g)
    elseif kind == "series" then
        body = series(state, g)
    elseif kind == "stats" then
        body = stats(state, g)
    elseif kind == "diagnostics" then
        body = diagnostics(state, g)
    elseif kind == "hub_settings" then
        body = hubSettings(state, g)
    else
        body = listBody(state, g)
    end
    cover_rects = nil
    local body_widgets = {}
    if not View.isList(kind) and kind ~= "settings" and kind ~= "hub_settings" and kind ~= "diagnostics" then
        body_widgets[#body_widgets + 1] = notice(state, g.content, false)
    end
    body_widgets[#body_widgets + 1] = body
    local content = stack({ w = g.content, gap = px(6) }, body_widgets)
    state.measuredBodyHeight = content:getSize().h
    state.bodyHitFirst, state.bodyHitLast = hit_start + 1, UI.hitMark()
    state.bodyBounds = Geom:new { x = g.margin, y = g.header, w = g.content, h = g.body }
    if View.isList(kind) then
        state.scrolling = nil
        return UI.overlay(w, h, {
            { widget = header(g, state) },
            { widget = content, x = g.margin, y = g.header },
            { widget = footer(g, state.tab), y = h - g.footer },
        })
    end
    local scrolling = ScrollableContainer:new {
        dimen = Geom:new { w = g.content + px(10), h = g.body },
        scroll_bar_width = px(3),
        swipe_full_view = true,
        ignore_events = { "touch", "pan", "pan_release", "hold", "hold_pan", "hold_release" },
        content,
    }
    scrolling:setScrolledOffset(state.route.scroll)
    state.scrolling = scrolling
    return UI.overlay(w, h, {
        { widget = header(g, state) },
        { widget = scrolling, x = g.margin, y = g.header },
        { widget = footer(g, state.tab), y = h - g.footer },
    })
end

View.heading, View.actions = heading, actions
return View
