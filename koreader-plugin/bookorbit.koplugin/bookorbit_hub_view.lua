-- Native widgets shared by every BookOrbit hub screen. No web view or animation.
local UI = require("bookorbit_board_ui")
local MenuUI = require("bookorbit_menu_ui")
local Theme = require("bookorbit_hub_theme")
local Model = require("bookorbit_hub_model")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Geom = require("ui/geometry")
local px, ink = Theme.px, Theme.ink
local text, row, space = UI.text, UI.hstack, UI.space
local function stack(options, items)
    local spaced = {}
    for _, item in ipairs(items) do
        if #spaced > 0 and options.gap and options.gap > 0 then spaced[#spaced + 1] = space(1, options.gap) end
        spaced[#spaced + 1] = item
    end
    return UI.vstack(options, spaced)
end
local View = {}

local function label(value, size, width, options)
    options = options or {}; options.s = size; options.w = width
    return text(value, options)
end

function View.button(title, width, action, primary, icon_name)
    local h, border = px(Theme.button), math.max(1, px(1))
    local parts = { UI.flex(0) }
    if icon_name then parts[#parts + 1] = UI.icon(icon_name, px(20), {col = primary and "white" or "black"}); parts[#parts + 1] = space(px(7), 1) end
    parts[#parts + 1] = label(title, Theme.body, width - px(icon_name and 48 or 20), {b = primary, align = "center", col = primary and ink.white or (action and ink.black or ink.g8)})
    parts[#parts + 1] = UI.flex(0)
    local widget = UI.box({w = width, h = h, border = border, border_col = ink.black, radius = px(5), bg = primary and ink.black or ink.white},
        row({w = width - 2 * border, h = h - 2 * border}, parts))
    return action and UI.hit(widget, action) or widget
end

local function iconButton(name, action)
    local s = px(44)
    return UI.hit(row({w = s, h = s}, {UI.flex(0), UI.icon(name, px(23)), UI.flex(0)}), action)
end

local function heading(title, w, action, subtitle)
    local parts = {label(title, Theme.heading, w - (action and px(86) or 0), {serif = true, b = true})}
    if action then parts[#parts + 1] = UI.hit(row({w = px(86), h = px(36)}, {label("See all ›", Theme.small, px(86), {align = "right"})}), action) end
    local line = row({w = w, h = px(36)}, parts)
    if subtitle and subtitle ~= "" then return stack({w = w, gap = px(2)}, {line, label(subtitle, Theme.small, w, {col = ink.g5})}) end
    return line
end

function View.cover(book, w, h)
    return UI.cover(book, w, h, {path = book.coverPath, border = math.max(1, px(.5)), border_col = ink.g8, valign = "center"})
end

function View.card(book, w, compact)
    local h = px(compact and 72 or Theme.row)
    local padding, gap = px(8), px(12)
    local border = math.max(1, px(.6))
    local cw, ch = px(compact and 38 or 63), h - 2 * padding - 2 * border
    local tw = w - 2 * border - 2 * padding - cw - 2 * gap - px(15)
    local details = {
        label(book.displayTitle or book.title or "Untitled", compact and 17 or 19, tw, {serif = true, b = true, lines = compact and 1 or 2}),
        label(table.concat(book.authors or {}, ", "), Theme.small, tw, {col = ink.g5}),
    }
    if not compact and Model.meta(book) ~= "" then details[#details + 1] = label(Model.meta(book), 12, tw, {col = ink.g5}) end
    local status = book.hint or (book.request and Model.stage(book.request) or Model.status(book))
    local percent = Model.percent(book.request and book.request.status == "downloading" and book.request.progressPercent or (not book.request and book.progressPercentage))
    if percent then status = status .. string.format(" · %d%%", percent) end
    details[#details + 1] = label(status, Theme.small, tw, {b = true})
    local content = stack({w = w - 2 * border, h = h - 2 * border, pad = padding}, {row({w = w - 2 * border - 2 * padding, h = ch, gap = gap}, {
        View.cover(book, cw, ch), stack({w = tw, gap = px(2)}, details), UI.icon("chevron-right", px(15)),
    })})
    return UI.hit(UI.box({w = w, h = h, border = border, border_col = ink.g8, radius = px(5), bg = ink.white}, content), book.action or {kind = "book", book = book})
end

function View.listCard(book, w)
    local h, gap, pad = px(Theme.listRow), px(10), px(5)
    local cw, ch = px(36), h - pad * 2
    local tw = w - cw - 2 * pad - 3 * gap - px(12) - 2 * math.max(1, px(.5))
    local status = book.hint or (book.request and Model.stage(book.request) or Model.status(book))
    local meta = Model.meta(book)
    local lines = stack({w = tw, gap = px(1)}, {
        label(book.displayTitle or book.title, 16, tw, {serif = true, b = true}),
        label(table.concat(book.authors or {}, ", "), 12, tw, {col = ink.g5}),
        label(status .. (meta ~= "" and (" · " .. meta) or ""), 11, tw, {col = ink.g5}),
    })
    return UI.hit(UI.box({w = w, h = h, border = math.max(1, px(.5)), border_col = ink.g8, bg = ink.white},
        row({w = w - 2, h = h - 2, gap = gap}, {space(pad, 1), View.cover(book, cw, ch), lines, UI.icon("chevron-right", px(12))})), book.action or {kind = "book", book = book})
end

local listKinds = {roulette=true, matches=true,discover=true, search=true, browse=true, books=true, requests=true, releases=true, series_list=true, author_list=true, genre_list=true, wishlist=true, collections=true, series=true}
function View.isList(kind) return listKinds[kind] == true end

local function shelf(books, w, count, compact)
    count = math.min(count or 4, #books)
    if count == 0 then return label("Explore your library or discover something new.", Theme.body, w, {lines = 2}) end
    local gap = px(12)
    local cw = math.floor((w - (count - 1) * gap) / count)
    local ch = math.min(math.floor(cw * 1.45), px(compact and 124 or 148))
    local cards = {}
    for i = 1, count do
        local book = books[i]
        cards[#cards + 1] = UI.hit(stack({w = cw, gap = px(4)}, {
            View.cover(book, cw, ch), label(book.title, 14, cw, {serif = true, b = true, lines = 2}),
            label(table.concat(book.authors or {}, ", "), 11, cw, {col = ink.g5}),
        }), {kind = "book", book = book})
    end
    return row({w = w, gap = gap, valign = "top"}, cards)
end

local function actions(buttons, w)
    local children, gap = {}, px(8)
    local width = math.floor((w - gap * (#buttons - 1)) / #buttons)
    for _, b in ipairs(buttons) do children[#children + 1] = View.button(b[1], width, b[2], b[3], b[4]) end
    return row({w = w, gap = gap}, children)
end

local function footer(g, tab)
    local tabs = {{"home", "Home", "house"}, {"discover", "Discover", "compass"}, {"books", "My Books", "library"}, {"requests", "Requests", "list"}}
    local parts, width = {}, math.floor(g.w / 4)
    for _, item in ipairs(tabs) do
        local selected = item[1] == tab
        parts[#parts + 1] = UI.hit(stack({w = width, h = g.footer - px(1), align = "center", gap = px(3), pad = {px(6), 0, px(6), 0}}, {
            UI.icon(item[3], px(24), {sw = selected and 2.7 or 1.8}),
            label(item[2], Theme.small, width, {align = "center", b = selected}),
            selected and UI.rect(px(62), px(3), ink.black, px(1)) or space(1, px(3)),
        }), {kind = "tab", tab = item[1]})
    end
    return stack({w = g.w}, {UI.rect(g.w, math.max(1, px(.5)), ink.g8), row({w = g.w, h = g.footer - px(1)}, parts)})
end

local function header(g, state)
    local brand_width = g.content - px(state.updateVersion and 176 or 132)
    local brand = label("BookOrbit", Theme.brand, brand_width, {serif = true, b = true})
    return stack({w = g.w, pad = {px(8), g.margin, px(8), g.margin}, gap = px(7)}, {
        row({w = g.content, h = px(44)}, {
            iconButton("chevron-left", {kind = "back"}), UI.hit(brand, {kind = "tab", tab = "home"}),
            iconButton("refresh-cw", {kind = "refresh"}), state.updateVersion and iconButton("download", {kind = "update"}) or space(0, 1), iconButton("sliders-horizontal", {kind = "settings"}),
        }),
        View.button(state.route.q or "Search books, authors, series, ISBN…", g.content, {kind = "search"}, false, "search"),
    })
end

local function listBody(state, g)
    local body, r, w = state.body or {}, state.route, g.content
    local children = {heading(state.title or "Books", w)}
    if r.kind == "search" or r.kind == "browse" then
        local scopes = {"all", "library", "requestable"}
        local selected = r.scope == "library" and 2 or r.scope == "requestable" and 3 or 1
        children[#children + 1] = MenuUI.segmented(w, {"All", "In Library", "Requestable"}, selected, function(i) return {kind = "scope", scope = scopes[i]} end)
    elseif r.kind == "requests" then
        local filters = {"all", "pending", "processing", "ready", "failed"}
        local selected = 1; for i, value in ipairs(filters) do if r.filter == value then selected = i end end
        children[#children + 1] = MenuUI.segmented(w, {"All", "Pending", "Active", "Ready", "Failed"}, selected, function(i) return {kind = "request_filter", filter = filters[i]} end)
    elseif r.kind == "books" then
        local filters = {"recent", "local", "reading"}
        local selected = r.filter == "local" and 2 or r.filter == "reading" and 3 or 1
        children[#children + 1] = MenuUI.segmented(w, {"Library", "On Device", "Reading"}, selected, function(i) return {kind = "books_filter", filter = filters[i]} end)
    end
    if r.kind == "discover" or r.kind == "genre_list" then
        children[#children + 1] = actions({{"Roulette", {kind="roulette"}}, {"Matches", {kind="matches"}}, {"Genres", {kind="genre_list"}}, {"More", {kind="discover_more"}}}, w)
    end
    if r.kind == "matches" then
        children[#children+1] = actions({{"Filters",{kind="match_filters"}}, {state.selectingMatches and "Done selecting" or "Select",{kind="match_select"}}, {"Add ("..tostring(state.selectedCount or 0)..")",(state.selectedCount or 0)>0 and {kind="match_acquire"} or nil}},w)
    end
    if r.kind == "search" or r.kind == "browse" or r.kind == "books" then
        children[#children + 1] = View.button(state.filterLabel or "Filters & sort", w, {kind="filters"}, false, "sliders-horizontal")
    end
    local notice = state.loading and "Loading…" or state.error or (state.cached and "Saved results" or nil)
    if body.partial or body.truncated then notice = (notice and (notice .. " · ") or "") .. "Some sources unavailable · Refresh or refine" end
    if notice then children[#children+1] = label(notice, Theme.small, w, {col=ink.g5, lines=1}) end
    if state.subtitle then children[#children+1] = label(state.subtitle, Theme.small, w, {col=ink.g5, lines=1}) end
    local books = state.visible or {}
    for _, book in ipairs(books) do children[#children + 1] = View.listCard(book, w) end
    if #books == 0 then children[#children + 1] = label(state.empty or "No books here yet. Try search or another filter.", Theme.body, w, {lines = 3}) end
    local pager_width = math.floor((w - px(16)) / 3)
    local pager = row({w=w, gap=px(8), h=px(Theme.button)}, {
        View.button("‹ Previous", pager_width, state.previous and {kind="page", delta=-1} or nil),
        label(state.pageLabel or "Page 1", Theme.small, pager_width, {align="center", b=true}),
        View.button("Next ›", pager_width, state.next and {kind="page", delta=1} or nil),
    })
    local content = stack({w = w, gap = px(7)}, children)
    state.listContentHeight = content:getSize().h
    return stack({w = w}, {content, space(1, math.max(0, g.body - content:getSize().h - pager:getSize().h)), pager})
end

local function requestDetail(state, g)
    local b, r, w = state.book or {}, state.body or {}, g.content
    local children = {heading("Book Request", w), View.card(b, w),
        heading(Model.stage(r), w),
        label("Requested  ›  Searching  ›  Downloading  ›  Importing  ›  Ready", Theme.small, w, {lines = 2, col = ink.g5}),
    }
    local percent = r.status == "downloading" and Model.percent(r.progressPercent)
    if percent then children[#children + 1] = UI.bar(w, px(8), percent); children[#children + 1] = label(string.format("%d%% reported by the downloader", percent), Theme.small, w) end
    if r.status == "pending" then children[#children + 1] = label("Waiting for administrator approval. BookOrbit will use your configured sources after approval.", Theme.body, w, {lines = 3})
    elseif r.status == "failed" then children[#children + 1] = label("Acquisition failed. Use Change file to choose another release, or retry if permitted.", Theme.body, w, {lines = 3})
    elseif r.status == "needs_review" then children[#children + 1] = label(r.languageNeedsReview and "The downloaded language did not match. The import is held for review." or "The import needs administrator review.", Theme.body, w, {lines = 3}) end
    if r.status == "available" and r.bookId and not r.replacementBookId then children[#children + 1] = View.button(b.localPath and "Read now" or "Download and read", w, {kind = "primary", book = b}, true, "book-open") end
    if r.status == "available" and r.replacementBookId then children[#children + 1] = View.button("Download replacement", w, {kind = "swap", bookId = r.bookId, previousBookId = r.replacementBookId}) end
    children[#children + 1] = View.button("Refresh status", w, {kind = "refresh"}, false, "refresh-cw")
    if r.canChooseRelease then children[#children + 1] = View.button("Change file", w, {kind = "releases"}) end
    if r.canRetry then children[#children + 1] = View.button("Retry automatic acquisition", w, {kind = "retry"}) end
    if r.canDiscardHeld then children[#children + 1] = View.button("Discard held file and try another release", w, {kind = "discard_held"}) end
    if r.canReplace then children[#children + 1] = View.button("Change file", w, {kind = "replace_request"}) end
    if r.canCancel then children[#children + 1] = View.button("Cancel request", w, {kind = "cancel_request"}) end
    children[#children + 1] = label("Status refreshes when you open this page or tap Refresh. Acquisition continues safely on the server while your Kobo sleeps.", Theme.small, w, {lines = 3, col = ink.g5})
    return stack({w = w, gap = px(12)}, children)
end

local function home(state, g)
    local body, w = state.body or {}, g.content
    local children = {
        heading("For You", w, {kind = "tab", tab = "discover"}, body.recommendationReason or "Discover your next book"),
        shelf(state.recommendations or {}, w, 4, true),
        heading("Continue Reading", w, {kind = "books_filter", filter = "reading"}),
    }
    if state.continueReading and state.continueReading[1] then children[#children + 1] = View.card(state.continueReading[1], w, true)
    else children[#children + 1] = label("Your next chapter starts in My Books.", Theme.small, w) end
    children[#children + 1] = heading("Recent Requests", w, {kind = "tab", tab = "requests"})
    if state.requests and state.requests[1] then children[#children + 1] = View.card(state.requests[1], w, true)
    else children[#children + 1] = label(body.requestsUnavailable and "Requests unavailable. Refresh to try again." or "No recent requests.", Theme.small, w) end
    children[#children + 1] = actions({{"Series", {kind = "series_list"}}, {"Releases", {kind = "new_releases"}}, {"Activity", {kind = "books_filter", filter = "recent"}}, {"Downloads", {kind = "books_filter", filter = "local"}}}, w)
    if state.canResume then table.insert(children,1,View.button("Resume Reading",w,{kind="resume_reading"},true)) end
    return stack({w = w, gap = px(7)}, children)
end

local function detail(state, g)
    local b, w = state.book or {}, g.content
    local cw, gap = math.floor(w * .29), px(16)
    local tw = w - cw - gap
    local metadata = Model.meta(b)
    if b.pageCount then metadata = metadata .. " · " .. b.pageCount .. " pages" end
    local info = {label(b.title, 25, tw, {serif = true, b = true, lines = 3}),
        label(table.concat(b.authors or {}, ", "), 17, tw, {serif = true, lines = 2}),
        label(metadata, Theme.small, tw, {lines = 2, col = ink.g5}),
        label(Model.status(b), Theme.small, tw, {b = true})}
    if b.rating then info[#info + 1] = label("Your rating: " .. tostring(b.rating) .. " / 5", Theme.small, tw) end
    if b.communityRating then info[#info + 1] = label(string.format("%.1f / 5", b.communityRating) .. (b.communityRatingCount and (" · " .. b.communityRatingCount .. " ratings") or ""), Theme.small, tw) end
    local children = {row({w = w, gap = gap, valign = "top"}, {View.cover(b, cw, math.floor(cw * 1.45)), stack({w = tw, gap = px(6)}, info)})}
    children[#children + 1] = actions({{b.localPath and "Read" or b.bookId and "Download" or b.requestId and "View request" or b.matchKey and "Add to Library" or "Request book", {kind = "primary", book = b}, true},
        {b.wishlistKey and "Remove wishlist" or "Add to Wishlist", {kind = "save_wishlist", book = b}}}, w)
    if b.matchKey then children[#children+1] = View.button("Remove from Matches",w,{kind="match_remove",book=b}) end
    children[#children + 1] = label(Model.plain(b.description) ~= "" and Model.plain(b.description) or "No description supplied by this catalog.", Theme.body, w, {serif = true, lines = 5})
    children[#children + 1] = actions({{"Description & editions", {kind = "editions", book = b}}, {b.bookId and "Collections / files" or "Request / sources", {kind = "book_options", book = b}}}, w)
    children[#children + 1] = heading("Explore related books", w)
    children[#children + 1] = actions({{"By this author", {kind = "author", q = b.authors and b.authors[1]}}, {b.seriesName and "In this series" or "Related genres", {kind = b.seriesName and "series" or "genres", book = b, q = b.seriesName}}}, w)
    if state.related and #state.related > 0 then children[#children + 1] = shelf(state.related, w, 4) end
    return stack({w = w, gap = px(12)}, children)
end

local function series(state, g)
    local body, w = state.body or {}, g.content
    local a = Model.seriesActions(body)
    local children = {heading(state.route.q or "Series", w),
        label(#(body.items or {}) .. " known records · " .. (body.orderingComplete and "Numbered reading order" or "Some volume positions are unknown"), Theme.small, w, {lines = 2, col = ink.g5}),
        actions({{"Continue series", a.continue and {kind = "book", book = a.continue} or nil}, {"Request missing", a.complete and #a.missing > 0 and {kind = "request_series"} or nil}}, w),
    }
    for _, b in ipairs(state.visible or {}) do children[#children + 1] = View.listCard(b, w) end
    children[#children + 1] = label(state.pageLabel or "Page 1", Theme.small, w, {align="center", b=true})
    children[#children + 1] = actions({{"‹ Previous", state.previous and {kind = "page", delta = -1} or nil}, {"Download in order", #a.owned > 0 and {kind = "download_series"} or nil}, {"Next ›", state.next and {kind = "page", delta = 1} or nil}}, w)
    if not body.orderingComplete then children[#children + 1] = label("Bulk actions use confirmed volume numbers only. Choose unnumbered editions individually.", Theme.small, w, {lines = 2, col = ink.g5}) end
    return stack({w = w, gap = px(10)}, children)
end

local function roulette(state,g)
    local w,b=g.content,state.book
    local children={heading("Book Roulette",w)}
    local notice=state.loading and "Finding recommendations…" or state.error or (state.cached and "Saved on this Kobo · Refresh when connected") or (state.body.partial and "Some catalog data is unavailable. You can retry with Refresh.")
    if notice then children[#children+1]=label(notice,Theme.small,w,{lines=1,col=ink.g5}) end
    if not state.body.onboarded then children[#children+1]=View.button("Choose your favorite books & genres",w,{kind="roulette_tastes"}) end
    if b then
        local ch=math.min(px(130),math.floor(g.body*.24));local cw=math.floor(ch/1.45);local tw=w-cw-px(14)
        children[#children+1]=row({w=w,gap=px(14),valign="top"},{View.cover(b,cw,ch),stack({w=tw,gap=px(5)}, {
            label(b.title,22,tw,{serif=true,b=true,lines=3}),label(table.concat(b.authors or {},", "),15,tw,{lines=2}),
            label(table.concat(b.genres or {}," · "),Theme.small,tw,{lines=2,col=ink.g5}),
        })})
        children[#children+1]=label(Model.plain(b.description or "No synopsis supplied. Open More for available details."),Theme.body,w,{serif=true,lines=state.body.onboarded and 4 or 2})
        children[#children+1]=label(b.recommendationWhy or "An exploratory suggestion",Theme.small,w,{lines=2,b=true})
    else children[#children+1]=label(state.loading and "Finding books…" or state.error or "No new picks right now. Change your tastes, undo a decision, or refresh later.",Theme.body,w,{lines=3}) end
    local controls=stack({w=w,gap=px(8)},{
        actions({{"Pass",b and {kind="roulette_decide",decision="pass",book=b}}, {"Match",b and {kind="roulette_decide",decision="match",book=b},true}, {"Skip",b and {kind="roulette_decide",decision="skip",book=b}}},w),
        actions({{"Undo",{kind="roulette_undo"}}, {"Matches",{kind="matches"}}, {"More",{kind="roulette_more"}}},w),
    })
    local content=stack({w=w,gap=px(7)},children)
    return stack({w=w},{content,space(1,math.max(0,g.body-content:getSize().h-controls:getSize().h)),controls})
end

local function settings(state, g)
    local w = g.content
    return stack({w=w, gap=px(14)}, {
        heading("Settings", w, nil, "BookOrbit " .. (state.version or "") .. " · " .. (state.username or "")),
        heading("Reading & device", w),
        actions({{"Display & text", {kind="setting", view="home"}}, {"Startup & shortcuts", {kind="setting", view="opening"}}}, w),
        actions({{"Downloads", {kind="setting", view="downloads"}}, {"Storage", {kind="storage"}}}, w),
        heading("Account & sync", w),
        actions({{"Account", {kind="setting", view="account"}}, {"Sync preferences", {kind="setting", view="sync"}}}, w),
        actions({{"Sync now", {kind="sync_now"}}, {"Sync status", {kind="sync_status"}}}, w),
        heading("Application", w),
        View.button(state.updateVersion and ("Update to " .. state.updateVersion) or "About & updates", w, {kind="setting", view="about"}, state.updateVersion ~= nil),
        actions({{"Classic catalog", {kind="classic"}}, {"KOReader files", {kind="close_hub"}}}, w),
    })
end

function View.build(state, w, h)
    local g = Theme.geometry(w, h)
    -- Reserve the native scrollbar's width. It appears only when font scaling
    -- or a long page needs another screenful; there is no animated scrolling.
    g.content = g.content - px(10)
    local hit_start = UI.hitMark()
    local kind = state.route.kind
    local body
    if kind == "roulette" then body = roulette(state,g)
    elseif kind == "home" then body = home(state, g)
    elseif kind == "settings" then body = settings(state, g)
    elseif kind == "discover" then body = listBody(state, g)
    elseif kind == "detail" then body = detail(state, g)
    elseif kind == "request_detail" then body = requestDetail(state, g)
    elseif kind == "series" then body = series(state, g)
    else body = listBody(state, g) end
    local note = state.loading and "Loading…" or state.error or (state.cached and "Saved on this Kobo · Refresh for the latest status" or nil)
    local body_widgets = {}
    if note and not View.isList(kind) then body_widgets[#body_widgets + 1] = label(note, Theme.small, g.content, {lines = 1, col = ink.g5}) end
    body_widgets[#body_widgets + 1] = body
    local content = stack({w = g.content, gap = px(6)}, body_widgets)
    state.measuredBodyHeight = content:getSize().h
    state.bodyHitFirst, state.bodyHitLast = hit_start + 1, UI.hitMark()
    state.bodyBounds = Geom:new{x = g.margin, y = g.header, w = g.content, h = g.body}
    if View.isList(kind) then
        state.scrolling = nil
        return UI.overlay(w, h, {{widget=header(g, state)}, {widget=content, x=g.margin, y=g.header}, {widget=footer(g, state.tab), y=h-g.footer}})
    end
    local scrolling = ScrollableContainer:new{
        dimen = Geom:new{w = g.content + px(10), h = g.body},
        scroll_bar_width = px(3), swipe_full_view = true,
        ignore_events = {"touch", "pan", "pan_release", "hold", "hold_pan", "hold_release"},
        content,
    }
    scrolling:setScrolledOffset(state.route.scroll)
    state.scrolling = scrolling
    return UI.overlay(w, h, {
        {widget = header(g, state)},
        {widget = scrolling, x = g.margin, y = g.header},
        {widget = footer(g, state.tab), y = h - g.footer},
    })
end

View.heading, View.actions = heading, actions
return View
