-- BookOrbit's native navigation shell. Catalog delivery/sync remain upstream.
local Api = require("bookorbit_api")
local Catalog = require("bookorbit_catalog")
local MenuPage = require("bookorbit_menu_page")
local View = require("bookorbit_hub_view")
local Model = require("bookorbit_hub_model")
local Theme = require("bookorbit_hub_theme")
local ListCache = require("bookorbit_list_cache")
local StateManager = require("bookorbit_state_manager")
local DownloadSheet = require("bookorbit_download_sheet")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Geom = require("ui/geometry")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local Toast = require("bookorbit_toast")
local Outbox = require("bookorbit_hub_outbox")
local Diag = require("bookorbit_hub_diag")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local socket = require("socket")
local Hub = {}
Hub.__index = Hub
local ROOT = "/koreader/plugin/"
-- Request watching: delays between checks while BookOrbit is open, and how long
-- a request may go without any change before this Kobo stops following it.
local WATCH_DELAYS = { 15, 30, 60, 120, 300 }
local WATCH_STALE_SECONDS = 7 * 24 * 3600
-- Covers that arrive close together share one repaint.
local COVER_REPAINT_DELAY = 0.3
-- The next page of a list is fetched this long after the current one settles.
local PREFETCH_DELAY = 2
-- Cards kept in the Roulette deck, and when to ask for more.
local ROULETTE_DECK = 20
local ROULETTE_REFILL_BELOW = 4
-- Background checks a reader opted into running without a subprocess stay short.
local DIRECT_TIMEOUT = { 3, 5 }

Hub.ROULETTE_REFILL_BELOW = ROULETTE_REFILL_BELOW

function Hub:rouletteDecided()
    return require("bookorbit_roulette").decided(self)
end

local function copy(value)
    local result = {}
    for k, v in pairs(value or {}) do
        result[k] = v
    end
    return result
end

function Hub:savePosition()
    if self.state and self.state.scrolling then
        self.route.scroll = self.state.scrolling:getScrolledOffset()
    end
    local r = self.route
    local saved = {
        kind = r.kind,
        q = r.q,
        field = r.field,
        scope = r.scope,
        filter = r.filter,
        page = r.page,
        subpage = r.subpage,
        displayPage = r.displayPage,
        genre = r.genre,
        language = r.language,
        author = r.author,
        series = r.series,
        sort = r.sort,
        readStatus = r.readStatus,
        format = r.format,
        refine = r.refine,
    }
    local previous = self.plugin.settings.hub_navigation
    local unchanged = previous and previous.account == self.account and previous.tab == self.tab and previous.route
    if unchanged then
        for k, v in pairs(saved) do
            if previous.route[k] ~= v then
                unchanged = false
                break
            end
        end
        for k, v in pairs(previous.route) do
            if saved[k] ~= v then
                unchanged = false
                break
            end
        end
    end
    if not unchanged then
        self.plugin.settings.hub_navigation = { account = self.account, tab = self.tab, route = saved }
        G_reader_settings:flush()
    end
end

function Hub:close()
    if self.closed then
        return
    end
    self:savePosition()
    self.closed = true
    for _, timer in ipairs({ "watchTimer", "coverTimer", "prefetchTimer", "outboxTimer", "refillTimer" }) do
        if self[timer] then
            UIManager:unschedule(self[timer])
            self[timer] = nil
        end
    end
    ListCache.flush()
    self.catalog.catalog_closed = true
    self.catalog:cancelThumbnailJobs()
    self.plugin._bookorbit_hub = nil
    if self.plugin.catalog_browser == self.page then
        self.plugin.catalog_browser = nil
    end
    if self.page and not self.page.closed then
        self.page:close()
    end
end

-- mode: KOReader's refresh mode ("ui" unless given). region: repaint only that
-- rectangle, for changes that stay inside it.
function Hub:refreshView(mode, region)
    if self.closed or not self.page then
        return
    end
    if self.state and self.state.scrolling then
        self.route.scroll = self.state.scrolling:getScrolledOffset()
    end
    if not region and not mode then
        -- A partial e-ink refresh leaves a ghost of what was there before. A new
        -- screen (navigation, tab, Back, page turn, the next Roulette card) gets a
        -- full flash; updates within a screen stay partial so they do not blink.
        local new_screen = self.bigChange
            or self.route ~= self.paintedRoute
            or self.route.subpage ~= self.paintedSubpage
        local policy = Model.setting(self.plugin.settings, "hub_flash_every")
        if new_screen then
            self.screens = (self.screens or 0) + 1
            local every = tonumber(policy)
            if policy == "screen" or (every and every > 0 and self.screens % every == 0) then
                self.flashNext = true
            end
        end
        self.paintedRoute, self.paintedSubpage, self.bigChange = self.route, self.route.subpage, false
    end
    if self.flashNext and not region then
        mode, self.flashNext = "full", false
    end
    self:present()
    self.page:refresh(mode, region)
    self.page.cropping_widget = self.state.scrolling
    self.catalog:scheduleThumbnailDownloads(self.visibleCovers)
end

-- Repaints only the notice line, when it is the one thing that changed (a
-- background refresh that found nothing new). Falls back to a full repaint.
function Hub:refreshNotice()
    local rect = self.state and self.state.noticeRect
    if rect and rect.w > 0 and rect.h > 0 then
        self:refreshView("ui", rect)
    else
        self:refreshView()
    end
end

-- Covers finished downloading. Only the covers that changed are repainted, in
-- one coalesced refresh; a batch that changed nothing on screen repaints nothing.
function Hub:coversArrived()
    if self.closed then
        return
    end
    if
        self.route
        and self.route.kind == "books"
        and self.route.filter == "local"
        and self.localListGeneration ~= self.catalog.on_device_generation
    then
        self:localBooks()
        self:refreshView()
        return
    end
    if self.coverTimer then
        return
    end
    self.coverTimer = function()
        self.coverTimer = nil
        if self.closed then
            return
        end
        local rects, missing = self.state.coverRects or {}, false
        local x0, y0, x1, y1
        for _, book in ipairs(self.visibleCovers or {}) do
            if not book.coverPath and self.catalog:cachedThumbnailPath(book) then
                local r = book.hub_cover_key and rects[book.hub_cover_key]
                if r then
                    x0 = math.min(x0 or r.x, r.x)
                    y0 = math.min(y0 or r.y, r.y)
                    x1 = math.max(x1 or (r.x + r.w), r.x + r.w)
                    y1 = math.max(y1 or (r.y + r.h), r.y + r.h)
                else
                    missing = true
                end
            end
        end
        if not x0 then
            if missing then
                -- Arrived for something not painted yet: draw it next time without a refresh now.
                self:present()
                self.page:rebuild()
            end
            return
        end
        local bounds = self.state.bodyBounds or self.page.dimen
        x0, y0 = math.max(x0, bounds.x), math.max(y0, bounds.y)
        x1, y1 = math.min(x1, bounds.x + bounds.w), math.min(y1, bounds.y + bounds.h)
        if x1 <= x0 or y1 <= y0 then
            self:present()
            self.page:rebuild()
            return
        end
        self:refreshView("ui", Geom:new { x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
    UIManager:scheduleIn(COVER_REPAINT_DELAY, self.coverTimer)
end

-- hidden: a book that is not drawn now (a prefetched page), whose cover is
-- fetched without repainting.
function Hub:prepare(raw, request, hidden)
    local b = Model.book(raw, request)
    if b.bookId then
        b.localPath = self.catalog:onDeviceBookPath({ id = b.bookId })
        if b.localPath then
            self.localMetadata = self.localMetadata or {}
            if not self.localMetadata[b.localPath] then
                local ok, settings = pcall(function()
                    return require("docsettings"):open(b.localPath)
                end)
                self.localMetadata[b.localPath] = ok
                        and {
                            props = settings:readSetting("doc_props") or {},
                            percent = settings:readSetting("percent_finished"),
                            summary = settings:readSetting("summary") or {},
                        }
                    or {}
            end
            local local_data = self.localMetadata[b.localPath]
            if type(local_data.percent) == "number" then
                b.progressPercentage = Model.percent(local_data.percent * 100)
            end
            if b.offlineMetadata then
                b.title = local_data.props and local_data.props.title or b.title
                if local_data.props and type(local_data.props.authors) == "string" then
                    b.authors = { local_data.props.authors }
                end
                b.readStatus = local_data.summary and local_data.summary.status or b.readStatus
            end
        end
        if b.hasCover ~= false then
            b.hub_cover_path = ROOT .. "catalog/books/" .. b.bookId .. "/thumbnail"
        end
    elseif b.coverUrl and b.coverUrl:match("^https://") then
        b.hub_cover_path = ROOT .. "discovery/cover?url=" .. Model.encode(b.coverUrl)
    end
    if b.hub_cover_path then
        b.hasCover = true
        b.hub_cover_key = md5(self.account .. "|" .. b.hub_cover_path .. "|" .. tostring(b.updatedAt or ""))
        b.coverPath = self.catalog:cachedThumbnailPath(b)
        if not hidden then
            self.visibleCovers[#self.visibleCovers + 1] = b
        end
    end
    return b
end

function Hub:present()
    local s, r = self.state, self.route
    s.route, s.tab = r, self.tab
    s.canResume = self.plugin.ui and self.plugin.ui.document ~= nil and self.plugin.ui.document == self.resumeDocument
    s.selectingMatches = self.selectingMatches
    s.selectedCount = 0
    for _ in pairs(self.selectedMatches or {}) do
        s.selectedCount = s.selectedCount + 1
    end
    self.visibleCovers = {}
    local g = Theme.geometry(Device.screen:getWidth(), Device.screen:getHeight())
    s.updateVersion = self.plugin.hasKnownUpdate
            and self.plugin:hasKnownUpdate()
            and self.plugin.settings.update_latest_version
        or nil
    s.version, s.username = self.plugin.PLUGIN_VERSION, self.plugin.settings.username
    local size = g.rows
    if r.kind == "discover" then
        s.body.items = s.body.recommendations or {}
    end
    if r.kind == "series" then
        size = math.max(1, math.floor((g.body - Theme.px(180)) / Theme.px(98)))
    end
    r.subpage = r.subpage or 1
    local body = s.body or {}
    if r.kind == "home" then
        s.recommendations, s.continueReading, s.requests, s.ready = {}, {}, {}, {}
        for _, request in ipairs(body.ready or {}) do
            if #s.ready < 4 and request.bookId then
                s.ready[#s.ready + 1] = self:prepare({
                    bookId = request.bookId,
                    title = request.title,
                    authors = request.authors,
                    seriesName = request.seriesName,
                    seriesIndex = request.seriesIndex,
                    updatedAt = request.updatedAt,
                })
            end
        end
        s.homeStats = Model.homeStats(body)
        for i, b in ipairs(body.recommendations or {}) do
            if i <= 4 then
                s.recommendations[#s.recommendations + 1] = self:prepare(b)
            end
        end
        for i, b in ipairs(body.continueReading or {}) do
            if i <= 1 then
                s.continueReading[#s.continueReading + 1] = self:prepare(b)
            end
        end
        for i, b in ipairs(body.requests or {}) do
            if i <= 1 then
                s.requests[#s.requests + 1] = self:prepare(b, true)
            end
        end
    elseif r.kind == "roulette" then
        local decided, hidden = self:rouletteDecided(), {}
        s.book, s.remaining = nil, 0
        for _, item in ipairs(body.items or {}) do
            if not decided[item.rouletteKey or ""] then
                s.remaining = s.remaining + 1
                if s.book then
                    hidden[#hidden + 1] = self:prepare(item, nil, true)
                else
                    s.book = self:prepare(item)
                end
            end
        end
        if r.seed then
            s.title = "More like " .. tostring(r.seed.title or "this")
        end
        -- The rest of the deck's covers come down quietly, so cards work offline.
        self.catalog:prefetchThumbnails(hidden, self.catalog.thumbnail_generation)
    elseif r.kind == "detail" then
        s.book = self:prepare(body.title and body or r.book)
        s.related = {}
        local related = body.relatedSections and body.relatedSections[1]
        for i, b in ipairs(related and related.books or {}) do
            if i <= 4 then
                s.related[#s.related + 1] = self:prepare(b)
            end
        end
    elseif r.kind == "request_detail" then
        s.book = self:prepare(body.title and body or r.request, true)
    elseif r.kind == "stats" then
        s.finished = {}
        for i, b in ipairs(body.recentlyFinished or {}) do
            if i <= 4 then
                s.finished[#s.finished + 1] = self:prepare(b)
            end
        end
    elseif r.kind == "hub_settings" then
        s.settings = self.plugin.settings
    elseif r.kind == "diagnostics" then
        s.diag = self:diagnostics()
    else
        s.visible = {}
        local items = body.items or {}
        r.subpage = math.max(1, math.min(r.subpage, math.max(1, math.ceil(#items / size))))
        for _, b in ipairs(Model.slice(items, r.subpage, size)) do
            local book = self:prepare(b, r.kind == "requests")
            if r.kind == "matches" and self.selectingMatches then
                book.displayTitle = ((self.selectedMatches or {})[book.matchKey] and "[x] " or "[ ] ") .. book.title
                book.action = { kind = "match_toggle", book = book }
            end
            if r.kind == "series" then
                book.displayTitle = (book.seriesIndex ~= nil and ("#" .. tostring(book.seriesIndex)) or "Unnumbered")
                    .. " · "
                    .. book.title
            end
            if r.kind == "series_list" then
                book.title = b.title or b.name
                book.authors = b.authorNames or {}
                book.action = { kind = "series", q = b.title or b.name, book = { authors = b.authorNames or {} } }
                book.hint = tostring(b.count or b.bookCount or "")
                    .. " in library · "
                    .. tostring(b.finishedCount or 0)
                    .. " read"
                local preview = b.previewBooks and b.previewBooks[1]
                if preview then
                    local cover = copy(preview)
                    cover.bookId = preview.id
                    book.coverPath = self:prepare(cover).coverPath
                end
            elseif r.kind == "author_list" then
                book.title = b.title or b.name
                book.authors = {}
                book.hint = tostring(b.count or b.bookCount or "") .. " books"
                book.action = { kind = "library_author", name = book.title }
            elseif r.kind == "genre_list" then
                book.title = b.name or b.title
                book.authors = {}
                book.action = { kind = "genre", q = book.title }
                book.hint = (b.count or 0) > 0
                        and (tostring(b.count) .. (b.count == 1 and " book" or " books") .. " in your library")
                    or "Browse the catalog"
            elseif r.kind == "collections" then
                book.title = b.name
                book.authors = {}
                book.action = { kind = "collection", collection = b }
                book.hint = tostring(b.bookCount or 0) .. " books"
            elseif r.kind == "social" then
                local verb = b.kind == "recommended" and "recommends"
                    or b.kind == "finished" and "finished"
                    or "is reading"
                book.hint = tostring(b.friend or "A reader")
                    .. " "
                    .. verb
                    .. (b.note and b.note ~= "" and (": " .. b.note) or "")
            elseif r.kind == "releases" then
                book.authors = { table.concat({ b.format or "?", Model.language(b.language), b.source or "" }, " · ") }
                book.hint = Model.bytes(b.sizeBytes)
                    .. (b.triedBefore and " · Previously tried" or "")
                    .. (b.vipOnly and " · VIP only" or "")
                book.action = { kind = "grab", release = b }
            end
            s.visible[#s.visible + 1] = book
        end
        local has_more = body.hasMore == true or (body.total and (r.page or 1) * (body.pageSize or 20) < body.total)
        s.previous = r.subpage > 1 or (r.page or 1) > 1
        s.next = r.subpage * size < #items or has_more
        s.pageLabel = "Page " .. tostring(r.displayPage or r.subpage)
        if not has_more and (r.page or 1) == 1 then
            s.pageLabel = s.pageLabel .. " of " .. math.max(1, math.ceil(#items / size))
        end
        local filters = {}
        for _, key in ipairs({ "genre", "author", "series", "language", "format", "readStatus", "field", "refine" }) do
            if r[key] and r[key] ~= "all" then
                filters[#filters + 1] = tostring(r[key])
            end
        end
        s.filterLabel = #filters > 0 and ("Filters: " .. table.concat(filters, " · ")) or "Filters & sort"
        s.title = r.kind == "browse" and r.q
            or r.kind == "author_list" and "Your authors"
            or r.kind == "genre_list" and "Genres"
            or r.kind == "discover" and "For You"
            or s.title
        if r.kind == "discover" then
            s.subtitle = body.recommendationReason
        end
        s.sliceSize = size
    end
end

-- What the Diagnostics screen shows: state that is otherwise invisible.
function Hub:diagnostics()
    local settings = self.plugin.settings
    local watched, outbox, events = {}, {}, {}
    for id, item in pairs(self:watched()) do
        watched[#watched + 1] = tostring(item.title or ("Request " .. id))
            .. " · "
            .. Model.stage({ status = item.status })
            .. " · changed "
            .. Model.ago(item.changedAt)
    end
    for _, e in ipairs(Outbox.items(self)) do
        outbox[#outbox + 1] = tostring(e.label)
            .. " · "
            .. Model.ago(e.created)
            .. ((e.attempts or 0) > 0 and (" · tried " .. e.attempts .. " times") or "")
    end
    local log = Diag.events(settings)
    for i = #log, math.max(1, #log - 11), -1 do
        local e = log[i]
        events[#events + 1] = Model.ago(e.t) .. " · " .. (e.kind == "error" and "Error: " or "") .. tostring(e.text)
    end
    local covers, cover_bytes = 0, 0
    local dir = self.catalog.thumbnail_cache_dir
    if dir and lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:match("%.jpg$") then
                covers = covers + 1
                cover_bytes = cover_bytes + (lfs.attributes(dir .. "/" .. name, "size") or 0)
            end
        end
    end
    local timings = {}
    for mode, t in pairs(Diag.timings()) do
        timings[#timings + 1] = (mode == "direct" and "Quick checks" or "Background process")
            .. string.format(": %d requests, average %.2f s, last %.2f s", t.count, t.average, t.last or 0)
    end
    table.sort(timings)
    local upkeep = settings.hub_upkeep_last
    return {
        version = self.plugin.PLUGIN_VERSION,
        user = settings.username,
        connected = NetworkMgr:isConnected(),
        watched = watched,
        outbox = outbox,
        cache = ListCache.stats(),
        covers = covers,
        coverBytes = cover_bytes,
        timings = timings,
        events = events,
        upkeep = type(upkeep) == "table" and (Model.ago(upkeep.at) .. " · " .. tostring(upkeep.summary or ""))
            or "Not run yet",
    }
end

function Hub:path(r)
    local page = tostring(r.page or 1)
    local extra = ""
    for _, key in ipairs({ "language", "genre", "sort", "refine" }) do
        if r[key] then
            extra = extra .. "&" .. key .. "=" .. Model.encode(r[key])
        end
    end
    if r.kind == "roulette" then
        local seed = ""
        if r.seed and r.seed.bookId then
            seed = "&seedBookId=" .. tostring(r.seed.bookId)
        elseif r.seed and r.seed.title then
            seed = "&seedTitle="
                .. Model.encode(r.seed.title)
                .. (r.seed.author and ("&seedAuthor=" .. Model.encode(r.seed.author)) or "")
                .. (r.seed.genre and ("&seedGenre=" .. Model.encode(r.seed.genre)) or "")
        end
        return ROOT .. "roulette?count=" .. ROULETTE_DECK .. seed
    elseif r.kind == "stats" then
        return ROOT .. "hub/stats"
    elseif r.kind == "social" then
        return ROOT .. "hub/social"
    elseif r.kind == "matches" then
        return ROOT
            .. "roulette/matches?page="
            .. page
            .. "&sort="
            .. (r.sort or "recent")
            .. (r.q and "&q=" .. Model.encode(r.q) or "")
            .. (r.genre and "&genre=" .. Model.encode(r.genre) or "")
    elseif r.kind == "home" then
        return ROOT .. "hub/home"
    elseif r.kind == "discover" then
        return ROOT .. "hub/discover"
    elseif r.kind == "search" then
        return ROOT
            .. "discovery/search?q="
            .. Model.encode(r.q)
            .. "&field="
            .. (r.field or "all")
            .. "&scope="
            .. (r.scope or "all")
            .. "&page="
            .. page
            .. extra
    elseif r.kind == "browse" then
        return ROOT
            .. "discovery/browse?q="
            .. Model.encode(r.q)
            .. "&mode="
            .. (r.mode or "subject")
            .. "&scope="
            .. (r.scope or "all")
            .. "&page="
            .. page
            .. extra
    elseif r.kind == "series" then
        return ROOT
            .. "discovery/series?q="
            .. Model.encode(r.q)
            .. (r.author and "&author=" .. Model.encode(r.author) or "")
    elseif r.kind == "author_list" then
        return ROOT .. "catalog/sections/authors?page=" .. page .. "&size=20"
    elseif r.kind == "series_list" then
        return ROOT .. "catalog/sections/series?page=" .. page .. "&size=20"
    elseif r.kind == "requests" then
        return ROOT .. "requests?page=" .. page .. "&filter=" .. (r.filter or "all")
    elseif r.kind == "request_detail" then
        return ROOT .. "requests/" .. r.id
    elseif r.kind == "releases" then
        return ROOT .. "requests/" .. r.id .. "/releases?page=" .. page .. "&refresh=" .. tostring(r.refresh == true)
    elseif r.kind == "genre_list" then
        return ROOT .. "hub/genres"
    elseif r.kind == "wishlist" then
        return ROOT .. "hub/wishlist?page=" .. page
    elseif r.kind == "collections" then
        return ROOT .. "hub/collections?page=" .. page
    elseif r.kind == "books" then
        if r.filter == "local" then
            return nil
        end
        local params = ""
        for _, key in ipairs({ "q", "author", "series", "collectionId", "format", "readStatus" }) do
            if r[key] then
                params = params .. "&" .. key .. "=" .. Model.encode(r[key])
            end
        end
        return ROOT
            .. "catalog/books?page="
            .. page
            .. "&size=20&sort="
            .. (r.sort or (r.filter == "reading" and "recently_read" or "recently_added"))
            .. (r.filter == "reading" and not r.readStatus and "&readStatus=reading" or "")
            .. params
            .. extra:gsub("&sort=[^&]*", "")
    elseif r.kind == "detail" then
        local b = r.book
        if b.bookId then
            return ROOT .. "catalog/books/" .. b.bookId
        end
        if b.providerKey == "openLibrary" and tostring(b.providerId):match("^OL%d+W$") then
            return ROOT .. "discovery/works/" .. b.providerId .. "?page=1"
        end
    end
end

local titles = {
    roulette = "Book Roulette",
    matches = "Matches",
    settings = "Settings",
    author_list = "Your authors",
    genre_list = "Genres",
    home = "Home",
    discover = "Discover",
    books = "My Books",
    requests = "Requests Queue",
    wishlist = "Wishlist",
    collections = "Collections",
    series_list = "Browse Series",
    releases = "Available releases",
    stats = "Reading stats",
    social = "Friends",
    diagnostics = "Diagnostics",
    hub_settings = "Hub options",
}

function Hub:navigate(route, replace, offline)
    if self.closed then
        return
    end
    if self.route then
        self:savePosition()
        if not replace then
            self.history[#self.history + 1] = { route = self.route, state = self.state, tab = self.tab }
            if #self.history > 20 then
                table.remove(self.history, 1)
            end
        end
    end
    self.route = route
    if route.kind == "home" or route.kind == "discover" or route.kind == "books" or route.kind == "requests" then
        self.tab = route.kind
    elseif route.kind == "search" or route.kind == "browse" or route.kind == "roulette" or route.kind == "matches" then
        self.tab = "discover"
    elseif
        route.kind == "series"
        or route.kind == "series_list"
        or route.kind == "wishlist"
        or route.kind == "collections"
    then
        self.tab = "books"
    elseif route.kind == "request_detail" or route.kind == "releases" then
        self.tab = "requests"
    elseif route.kind == "social" then
        self.tab = "discover"
    elseif route.kind == "stats" then
        self.tab = "books"
    end
    self.state = {
        route = route,
        title = titles[route.kind] or route.q or "BookOrbit",
        body = route.kind == "detail" and copy(route.book)
            or route.kind == "request_detail" and copy(route.request)
            or {},
    }
    if route.kind == "books" and route.filter == "local" then
        self:localBooks()
        self:refreshView()
        return
    end
    local path = self:path(route)
    if path then
        local cached = ListCache.load(self.account .. "|hub|" .. path)
        if cached then
            self.state.body = cached.body
            self.state.cached = true
            self.state.etag = cached.etag
        end
    end
    if path then
        self:load(
            offline
                or (
                    route.kind == "detail"
                    and route.book
                    and (
                        route.book.localPath ~= nil
                        or (route.book.bookId and self.catalog:onDeviceBookPath({ id = route.book.bookId }) ~= nil)
                    )
                )
        )
    else
        self:refreshView()
    end
end

function Hub:back()
    local previous = table.remove(self.history)
    if not previous then
        self:close()
        return
    end
    self:savePosition()
    self.route, self.state, self.tab = previous.route, previous.state, previous.tab
    self:refreshView()
    if self.route.kind == "requests" or self.route.kind == "matches" then
        self:load(true)
    end
end

-- Shows the saved copy at once and asks the server whether it changed. With a
-- saved copy on screen the check is quiet: only the notice line repaints, and
-- an unchanged reply (304) repaints nothing else.
function Hub:load(offline)
    local route, path = self.route, self:path(self.route)
    if not path then
        self:refreshView()
        return
    end
    local key = self.account .. "|hub|" .. path
    local background = self.state.cached == true and type(self.state.body) == "table" and next(self.state.body) ~= nil
    self:fetch(
        "GET",
        path,
        nil,
        function(body, etag)
            if route.kind == "detail" then
                local merged = copy(route.book)
                for k, value in pairs(body) do
                    merged[k] = value
                end
                body = merged
            end
            local changed = ListCache.stage(key, body, etag)
            self.state.body, self.state.cached, self.state.error, self.state.etag = body, false, nil, etag
            if route.kind == "request_detail" then
                route.request = body
                self:observe({ body })
            elseif route.kind == "requests" then
                self:observe(body.items or {})
            elseif route.kind == "home" then
                self:observe(body.requests or {})
                self:observe(body.ready or {})
            end
            if background and not changed then
                self:refreshNotice()
            else
                self:refreshView()
            end
            self:prefetchNext(route, body)
        end,
        offline,
        {
            background = background,
            etag = background and self.state.etag or nil,
            unchanged = function()
                ListCache.touch(key)
                self.state.cached, self.state.error = false, nil
                self:refreshNotice()
                self:prefetchNext(route, self.state.body)
            end,
        }
    )
end

-- One request with a loading notice. opts.background: a saved copy is on
-- screen, so only the notice line repaints. opts.etag and opts.unchanged: ask
-- whether the copy changed, and what to do when it did not (a 304).
function Hub:fetch(method, path, payload, done, offline, opts)
    opts = opts or {}
    if self.closed then
        return
    end
    local function repaint()
        if opts.background then
            self:refreshNotice()
        else
            self:refreshView()
        end
    end
    if self.busy then
        local active = self.activeFetch
        if method ~= "GET" and not (active and active.quiet) then
            Toast.show("Please wait for the current action to finish.")
            return
        end
        if active and active.method == method and active.path == path and active.route == self.route then
            return
        end
        self.pendingFetch = { method, path, payload, done, offline, opts, route = self.route }
        if not self.state.loading then
            self.state.loading = true
            repaint()
        end
        return
    end
    if not NetworkMgr:isConnected() then
        self.state.loading = false
        self.state.error = "Offline · Downloaded books are available in My Books"
        repaint()
        if not offline then
            NetworkMgr:runWhenConnected(function()
                if not self.closed then
                    self:fetch(method, path, payload, done, true, opts)
                end
            end)
        end
        return
    end
    local route = self.route
    self.activeFetch = { method = method, path = path, route = route }
    self.busy = true
    self.state.loading = true
    repaint()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local started = socket.gettime()
            local headers = opts.etag and { ["if-none-match"] = opts.etag } or nil
            local completed, result = self.client:runInSubprocess(function()
                local meta = {}
                local body, err, errbody = self.client:requestBlocking(method, path, payload, headers, meta)
                if body then
                    return { data = body, etag = meta.etag }
                end
                return nil, err, errbody
            end)
            Diag.timing("subprocess", socket.gettime() - started)
            self.busy = false
            self.activeFetch = nil
            if self.closed then
                return
            end
            if not self:sameAccount() then
                self:close()
                return
            end
            if route == self.route then
                self.state.loading = false
                local reply = completed and result and result.body
                if type(reply) == "table" and reply.data ~= nil then
                    Diag.guard(self, method .. " " .. path, done, reply.data, reply.etag)
                elseif completed and result and tonumber(result.err) == 304 and opts.unchanged then
                    opts.unchanged()
                else
                    self.state.error =
                        Model.errorText(method, completed, result and result.err, result and result.errbody)
                    Diag.event(
                        self.plugin.settings,
                        "error",
                        method .. " " .. path:gsub("%?.*", "") .. ": " .. tostring(result and result.err or "cancelled")
                    )
                    if method ~= "GET" then
                        Toast.error(self.state.error)
                    end
                    repaint()
                end
            end
            self:runPending()
        end)
    end)
end

function Hub:sameAccount()
    local settings = self.plugin.settings
    return self.account
        == md5(table.concat({ settings.server_url or "", settings.username or "", settings.userkey or "" }, "|"))
end

function Hub:runPending()
    local pending = self.pendingFetch
    self.pendingFetch = nil
    if pending and pending.route == self.route then
        self:fetch(pending[1], pending[2], pending[3], pending[4], pending[5], pending[6])
    elseif not self.busy then
        Outbox.drain(self)
    end
end

-- Requests this account is waiting on. Saved in settings so a book that
-- finishes while BookOrbit is closed still triggers a sync on the next open.
function Hub:watched()
    local saved = self.plugin.settings.hub_watched_requests
    if type(saved) ~= "table" or saved.account ~= self.account then
        saved = { account = self.account, items = {} }
        self.plugin.settings.hub_watched_requests = saved
    end
    return saved.items
end

-- Follows unfinished requests and reports the ones that became ready. A ready
-- request refreshes the library and queues one quiet sync.
function Hub:observe(requests)
    local items, ready, changed = self:watched(), {}, false
    for _, r in ipairs(requests or {}) do
        local key = r.id and tostring(r.id)
        local known = key and items[key]
        if key and Model.isSettled(r.status) then
            if known then
                items[key] = nil
                changed = true
                if r.status == "available" then
                    ready[#ready + 1] = r
                end
            end
        elseif key and r.status and (not known or known.status ~= r.status) then
            items[key] = { status = r.status, title = r.title, changedAt = os.time() }
            changed = true
        end
    end
    if changed then
        G_reader_settings:flush()
    end
    if #ready > 0 then
        require("bookorbit_hub_upkeep").soon(self.plugin, 10)
        self.plugin:onBookOrbitDownloadComplete()
        local title = ready[1].title or "Your book"
        Toast.show(#ready == 1 and (title .. " is ready to read.") or (#ready .. " requested books are ready to read."))
    end
    if changed then
        self:scheduleWatch(true)
    end
end

function Hub:scheduleWatch(reset, delay)
    if reset then
        self.watchStep = 1
    end
    if self.watchTimer then
        UIManager:unschedule(self.watchTimer)
        self.watchTimer = nil
    end
    if self.closed or next(self:watched()) == nil then
        return
    end
    self.watchTimer = function()
        self.watchTimer = nil
        self:checkWatched()
    end
    UIManager:scheduleIn(delay or WATCH_DELAYS[math.min(self.watchStep or 1, #WATCH_DELAYS)], self.watchTimer)
end

-- Asks only about the followed requests, with the tag of the last answer, so a
-- check where nothing moved is an empty 304. Never turns on Wi-Fi.
function Hub:checkWatched()
    if self.closed then
        return
    end
    local items, now, pruned = self:watched(), os.time(), false
    for key, item in pairs(items) do
        if type(item) ~= "table" or now - (item.changedAt or 0) > WATCH_STALE_SECONDS then
            items[key] = nil
            pruned = true
        end
    end
    if pruned then
        G_reader_settings:flush()
    end
    local ids = {}
    for key in pairs(items) do
        if key:match("^%d+$") then
            ids[#ids + 1] = key
        end
    end
    if #ids == 0 then
        return
    end
    if self.busy or not NetworkMgr:isConnected() then
        self:scheduleWatch(false, self.busy and 3 or nil)
        return
    end
    table.sort(ids, function(a, b)
        return tonumber(a) < tonumber(b)
    end)
    self.watchStep = (self.watchStep or 1) + 1
    local path = ROOT .. "requests/watch?ids=" .. table.concat(ids, ",", 1, math.min(#ids, 50))
    local previous = self.watchTag and self.watchTag.path == path and self.watchTag.etag or nil
    self:quietRequest("GET", path, nil, function(body, etag)
        self.watchTag = { path = path, etag = etag }
        local list, gone = {}, false
        for _, r in ipairs(body.items or {}) do
            if r.gone then
                items[tostring(r.id)] = nil
                gone = true
            else
                list[#list + 1] = r
            end
        end
        if gone then
            G_reader_settings:flush()
        end
        self:observe(list)
        self:showWatchedChanges(list)
        self:scheduleWatch(false)
    end, function()
        -- A 304 means nothing moved; any other failure waits for the next check.
        self:scheduleWatch(false)
    end, { etag = previous, direct = self.plugin.settings.hub_direct_requests == true })
end

-- Patches the requests on screen with their new state and repaints only when
-- something visible changed.
function Hub:showWatchedChanges(list)
    local route, state = self.route, self.state
    local function signature(r)
        return tostring(r.status) .. ":" .. tostring(r.progressPercent)
    end
    local fresh = {}
    for _, r in ipairs(list) do
        fresh[tostring(r.id)] = r
    end
    if route.kind == "request_detail" then
        local r = fresh[tostring(route.id)]
        if r and signature(r) ~= signature(state.body or {}) then
            route.request, state.body = r, r
            self:refreshView()
        end
        return
    end
    local items = route.kind == "requests" and (state.body or {}).items
        or route.kind == "home" and (state.body or {}).requests
    if type(items) ~= "table" then
        return
    end
    local changed = false
    for i, r in ipairs(items) do
        local update = fresh[tostring(r.id)]
        if update and signature(update) ~= signature(r) then
            items[i] = update
            changed = true
        end
    end
    if changed then
        local path = self:path(route)
        if path then
            ListCache.stage(self.account .. "|hub|" .. path, state.body)
        end
        self:refreshView()
    end
end

-- A background request: no loading notice, no error notice, no Wi-Fi prompt.
-- Actions tapped meanwhile wait in pendingFetch and run when it finishes.
-- opts.etag asks whether a copy changed (fail then gets 304); opts.direct runs
-- it in this process with a short timeout instead of a subprocess.
function Hub:quietRequest(method, path, payload, done, fail, opts)
    opts = opts or {}
    self.busy = true
    self.activeFetch = { method = method, path = path, route = self.route, quiet = true }
    local direct = opts.direct == true and method == "GET"
    Trapper:wrap(function()
        local started = socket.gettime()
        local headers = opts.etag and { ["if-none-match"] = opts.etag } or nil
        local function call()
            local meta = { timeout = direct and DIRECT_TIMEOUT or nil }
            local body, err, errbody = self.client:requestBlocking(method, path, payload, headers, meta)
            if body then
                return { data = body, etag = meta.etag }
            end
            return nil, err, errbody
        end
        local completed, result
        if direct then
            local ok, body, err, errbody = pcall(call)
            completed = true
            result = ok and { body = body, err = err, errbody = errbody } or { err = tostring(body) }
        else
            completed, result = self.client:runInSubprocess(call)
        end
        Diag.timing(direct and "direct" or "subprocess", socket.gettime() - started)
        self.busy = false
        self.activeFetch = nil
        if self.closed then
            return
        end
        if not self:sameAccount() then
            self:close()
            return
        end
        local reply = completed and result and result.body
        if type(reply) == "table" and reply.data ~= nil then
            Diag.guard(self, "background " .. path:gsub("%?.*", ""), done, reply.data, reply.etag)
        elseif fail then
            fail(completed and result and result.err or "cancelled", result and result.errbody)
        end
        self:runPending()
    end)
end

-- Lists worth reading ahead: answered by BookOrbit itself, so a prefetch never
-- holds a tap behind a slow public catalog.
local PREFETCH_KINDS = {
    books = true,
    requests = true,
    wishlist = true,
    collections = true,
    author_list = true,
    series_list = true,
    matches = true,
}

-- After a list settles: its next page and the first library books' details,
-- fetched quietly into the saved pages, covers included, without a repaint.
function Hub:prefetchNext(route, body)
    if self.prefetchTimer then
        UIManager:unschedule(self.prefetchTimer)
        self.prefetchTimer = nil
    end
    if not PREFETCH_KINDS[route.kind] or route.filter == "local" or type(body) ~= "table" then
        return
    end
    local targets = {}
    local has_more = body.hasMore == true or (body.total and (route.page or 1) * (body.pageSize or 20) < body.total)
    if has_more then
        local next_route = copy(route)
        next_route.page, next_route.subpage, next_route.scroll = (route.page or 1) + 1, 1, nil
        targets[#targets + 1] = { path = self:path(next_route), request = route.kind == "requests" }
    end
    for i, b in ipairs(self.state.visible or {}) do
        if i <= 2 and b.bookId and not b.request and not b.action then
            targets[#targets + 1] = { path = ROOT .. "catalog/books/" .. b.bookId }
        end
    end
    if #targets == 0 then
        return
    end
    self.prefetchTimer = function()
        self.prefetchTimer = nil
        self:prefetchPaths(targets, 1)
    end
    UIManager:scheduleIn(PREFETCH_DELAY, self.prefetchTimer)
end

function Hub:prefetchPaths(targets, index)
    local target = targets[index]
    if not target or not target.path or self.closed or self.busy or not NetworkMgr:isConnected() then
        return
    end
    local key = self.account .. "|hub|" .. target.path
    local saved = ListCache.get(key)
    if saved and os.time() - (saved.saved_at or 0) < 120 then
        return self:prefetchPaths(targets, index + 1)
    end
    self:quietRequest("GET", target.path, nil, function(body, etag)
        ListCache.stage(key, body, etag)
        local hidden = {}
        for _, item in ipairs(body.items or {}) do
            hidden[#hidden + 1] = self:prepare(item, target.request, true)
        end
        if #hidden > 0 then
            self.catalog:prefetchThumbnails(hidden, self.catalog.thumbnail_generation)
        end
        self:prefetchPaths(targets, index + 1)
    end, function(err)
        if tonumber(err) == 304 then
            ListCache.touch(key)
            self:prefetchPaths(targets, index + 1)
        end
    end, { etag = saved and saved.etag or nil })
end

function Hub:localBooks()
    self.catalog:refreshOnDevice()
    local items, total = {}, 0
    for id, path in pairs(self.catalog.on_device or {}) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            local name = path:match("([^/]+)$") or path
            local cached = ListCache.get(self.account .. "|hub-book|" .. tostring(id))
            local item = cached and copy(cached.body)
                or { title = name:gsub("%.[^%.]+$", ""), authors = {}, hasCover = false, offlineMetadata = true }
            item.bookId, item.localPath, item.sizeBytes = tonumber(id), path, attr.size
            items[#items + 1] = item
            total = total + attr.size
        end
    end
    table.sort(items, function(a, b)
        return a.title:lower() < b.title:lower()
    end)
    self.state.body = { items = items }
    self.state.subtitle = #items .. " downloaded · " .. Model.bytes(total) .. " used · Available offline"
    self.localBytes = total
    self.localListGeneration = self.catalog.on_device_generation
end

function Hub:openBook(book)
    if book.action then
        return self:action(book.action)
    end
    if book.request then
        return self:navigate({ kind = "request_detail", id = book.request.id, request = book.request })
    end
    self:navigate({ kind = "detail", book = book })
end

function Hub:prompt(mode, field)
    local dialog
    dialog = InputDialog:new {
        title = mode == "series" and "Find a series"
            or mode == "author" and "Browse an author"
            or "Search books, authors, series or ISBN",
        input = self.route.kind == "search" and self.route.q or "",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Search",
                    is_enter_default = true,
                    callback = function()
                        local q = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        if #q < 2 then
                            return
                        end
                        UIManager:close(dialog)
                        if mode == "series" then
                            self:navigate({ kind = "series", q = q })
                        elseif mode == "author" then
                            self:navigate({ kind = "browse", mode = "author", q = q })
                        else
                            self:navigate({ kind = "search", q = q, field = field or "all", scope = "all", page = 1 })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Hub:menu(title, rows)
    local menu
    menu = Menu:new {
        title = title,
        item_table = rows,
        width = Device.screen:getWidth(),
        items_max_lines = 2,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            if item.callback then
                item.callback()
            end
        end,
    }
    UIManager:show(menu)
end

function Hub:primary(book)
    if book.matchKey and not book.bookId and not book.requestId then
        require("bookorbit_roulette").acquire(self, { book.matchKey })
        return
    end
    if book.localPath then
        self.catalog:openDownloadedFile(book.localPath)
    elseif book.bookId then
        self:download(book, true)
    elseif book.requestId and not (book.availability and book.availability.alreadySubscribed == false) then
        self:navigate({
            kind = "request_detail",
            id = book.requestId,
            request = { id = book.requestId, title = book.title, authors = book.authors, status = book.requestStatus },
        })
    elseif not NetworkMgr:isConnected() then
        self:queue({
            method = "POST",
            path = ROOT .. "requests",
            payload = Model.requestPayload(book),
            label = "Request: " .. tostring(book.title),
            kind = "request",
            key = "request:" .. tostring(book.title) .. "|" .. tostring((book.authors or {})[1]),
        })
    else
        self:fetch("POST", ROOT .. "requests", Model.requestPayload(book), function(body)
            self:navigate({ kind = "request_detail", id = body.request.id, request = body.request })
        end)
    end
end

-- Saves an action for when BookOrbit can be reached, and says so.
function Hub:queue(entry)
    Outbox.add(self, entry)
    Toast.show("Saved. It will be sent when BookOrbit can be reached.")
    if self.route.kind == "diagnostics" then
        self:refreshView()
    end
end

-- A queued action reached BookOrbit.
function Hub:onOutboxSent(entry, body)
    if entry.kind == "roulette" then
        self.plugin.settings.roulette_last_event = body
                and not body.undone
                and { account = self.account, id = entry.payload.eventId }
            or nil
    elseif entry.kind == "request" and type(body) == "table" and body.request then
        self:observe({ body.request })
        Toast.show(tostring(body.request.title or "Your request") .. " was sent to BookOrbit.")
    elseif entry.kind ~= "report" then
        Toast.show(tostring(entry.label or "A saved action") .. " was sent.")
    end
    Diag.event(self.plugin.settings, "info", "Sent: " .. tostring(entry.label))
end

-- BookOrbit refused a queued action; it is not retried.
function Hub:onOutboxDropped(entry, err, errbody)
    local reason = Model.serverMessage(errbody) or tostring(err)
    Diag.event(self.plugin.settings, "error", "Not sent: " .. tostring(entry.label) .. " (" .. reason .. ")")
    if entry.kind ~= "report" and entry.kind ~= "roulette" then
        Toast.error(tostring(entry.label) .. " could not be sent: " .. reason)
    end
end

function Hub:download(book, start)
    self.catalog:runConnected(function()
        local detail, err = self.catalog:fetchDeliveryBook(book.bookId)
        if not detail then
            self.catalog:showWriteError(err)
            return
        end
        ListCache.put(self.account .. "|hub-book|" .. book.bookId, detail)
        DownloadSheet.open(self.catalog, detail, { start = start == true })
    end)
end

function Hub:changeFile(book, request)
    local function selected(body)
        local replacement = body.request
        if replacement.canChooseRelease then
            self:navigate({ kind = "releases", id = replacement.id, request = replacement, page = 1 })
        else
            self:navigate({ kind = "request_detail", id = replacement.id, request = replacement })
        end
    end
    if request then
        self:fetch("POST", ROOT .. "requests/" .. request.id .. "/replacement", { language = "en" }, selected)
        return
    end
    self:menu("Change file", {
        {
            text = "Choose an existing library file",
            callback = function()
                self.catalog:loadReplacement(book.bookId, book.bookId)
            end,
        },
        {
            text = "Choose a release from sources",
            callback = function()
                self:fetch(
                    "POST",
                    ROOT .. "requests/book/" .. book.bookId .. "/replacement",
                    { language = "en" },
                    selected
                )
            end,
        },
    })
end

function Hub:bookOptions(book)
    local rows = {}
    if book.bookId then
        rows[#rows + 1] = {
            text = "Add to or remove from a collection",
            callback = function()
                self:collectionPicker(book)
            end,
        }
        rows[#rows + 1] = {
            text = "Change file",
            callback = function()
                self:changeFile(book)
            end,
        }
        rows[#rows + 1] = {
            text = "Recommend to other readers",
            callback = function()
                self:recommend(book)
            end,
        }
        if book.localPath then
            rows[#rows + 1] = {
                text = "Remove download from this Kobo",
                callback = function()
                    self:removeLocal(book)
                end,
            }
        end
    elseif book.requestId then
        rows[#rows + 1] = {
            text = "View request and available releases",
            callback = function()
                self:primary(book)
            end,
        }
    else
        rows[#rows + 1] = {
            text = "Request through BookOrbit (English preferred)",
            callback = function()
                self:primary(book)
            end,
        }
    end
    self:menu("Book options", rows)
end

function Hub:editions(book, page, body)
    body = body or book
    local rows = {
        {
            text = "Full description",
            callback = function()
                UIManager:show(TextViewer:new {
                    title = book.title,
                    text = Model.plain(book.description) ~= "" and Model.plain(book.description)
                        or "No description supplied.",
                })
            end,
        },
    }
    for _, edition in ipairs(body.editions or {}) do
        local e = edition
        local languages = {}
        for _, lang in ipairs(e.languages or {}) do
            languages[#languages + 1] = Model.language(lang)
        end
        local description = table.concat({
            e.title or book.title,
            table.concat(languages, ", "),
            e.format or "",
            e.publisher or "",
            e.date or "",
            e.isbn13 or "",
        }, " · ")
        rows[#rows + 1] = {
            text = description,
            callback = function()
                UIManager:show(TextViewer:new {
                    title = "Edition metadata",
                    text = description
                        .. "\n\nThis catalog edition does not guarantee a downloadable release. Request the work, then use its available releases.",
                })
            end,
        }
    end
    if body.hasMore and book.providerKey == "openLibrary" then
        rows[#rows + 1] = {
            text = "More editions",
            callback = function()
                self:fetch(
                    "GET",
                    ROOT .. "discovery/works/" .. book.providerId .. "?page=" .. (page + 1),
                    nil,
                    function(next_page)
                        self:editions(book, page + 1, next_page)
                    end
                )
            end,
        }
    end
    self:menu("Description and editions · " .. page, rows)
end

function Hub:collectionPicker(book, page)
    page = page or 1
    local function show(body)
        local rows = {}
        for _, c in ipairs(body.items or {}) do
            local collection = c
            rows[#rows + 1] = {
                text = collection.name,
                callback = function()
                    self:menu(collection.name, {
                        {
                            text = "Add book",
                            callback = function()
                                if not NetworkMgr:isConnected() then
                                    return self:queue({
                                        method = "POST",
                                        path = ROOT .. "hub/collections/" .. collection.id .. "/books",
                                        payload = { bookId = book.bookId },
                                        label = "Add to " .. tostring(collection.name),
                                        kind = "collection",
                                        key = "collection:" .. collection.id .. ":" .. book.bookId,
                                    })
                                end
                                self:fetch(
                                    "POST",
                                    ROOT .. "hub/collections/" .. collection.id .. "/books",
                                    { bookId = book.bookId },
                                    function()
                                        Toast.show("Added to collection")
                                    end
                                )
                            end,
                        },
                        {
                            text = "Remove book",
                            callback = function()
                                if not NetworkMgr:isConnected() then
                                    return self:queue({
                                        method = "DELETE",
                                        path = ROOT .. "hub/collections/" .. collection.id .. "/books/" .. book.bookId,
                                        label = "Remove from " .. tostring(collection.name),
                                        kind = "collection",
                                        key = "collection:" .. collection.id .. ":" .. book.bookId,
                                    })
                                end
                                self:fetch(
                                    "DELETE",
                                    ROOT .. "hub/collections/" .. collection.id .. "/books/" .. book.bookId,
                                    nil,
                                    function()
                                        Toast.show("Removed from collection")
                                    end
                                )
                            end,
                        },
                    })
                end,
            }
        end
        if body.hasMore then
            rows[#rows + 1] = {
                text = "More collections",
                callback = function()
                    self:collectionPicker(book, page + 1)
                end,
            }
        end
        if NetworkMgr:isConnected() then
            rows[#rows + 1] = {
                text = "New collection with this book…",
                callback = function()
                    self:createCollection(book)
                end,
            }
        end
        self:menu("Your collections", rows)
    end
    if not NetworkMgr:isConnected() then
        -- Offline: the collections saved from the Collections tab; changes wait in the outbox.
        local saved = ListCache.get(self.account .. "|hub|" .. ROOT .. "hub/collections?page=" .. page)
        if saved then
            return show(saved.body)
        end
    end
    self:fetch("GET", ROOT .. "hub/collections?bookId=" .. book.bookId .. "&page=" .. page, nil, show)
end

-- Asks for a name, creates the collection and, given a book, adds it.
function Hub:createCollection(book)
    local dialog
    dialog = InputDialog:new {
        title = "New collection",
        input = "",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Create",
                    is_enter_default = true,
                    callback = function()
                        local name = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        if name == "" then
                            return
                        end
                        UIManager:close(dialog)
                        self:fetch("POST", ROOT .. "hub/collections", { name = name }, function(created)
                            if not (book and book.bookId) then
                                Toast.show("Created " .. tostring(created.name))
                                if self.route.kind == "collections" then
                                    self:load(true)
                                end
                                return
                            end
                            self:fetch(
                                "POST",
                                ROOT .. "hub/collections/" .. created.id .. "/books",
                                { bookId = book.bookId },
                                function()
                                    Toast.show("Created " .. tostring(created.name) .. " with this book")
                                end
                            )
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shares a library book with the other readers who turned sharing on.
function Hub:recommend(book)
    local dialog
    dialog = InputDialog:new {
        title = "Recommend to other readers",
        input = "",
        description = "Optional: a short note. Only readers who share their reading see it.",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Recommend",
                    is_enter_default = true,
                    callback = function()
                        local note = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        self:fetch(
                            "POST",
                            ROOT .. "hub/social/recommendations",
                            { bookId = book.bookId, note = note ~= "" and note:sub(1, 280) or nil },
                            function()
                                Toast.show("Recommended to other readers")
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

function Hub:removeLocal(book)
    local path = book.localPath
    if
        not path or not require("bookorbit_download_transfer").isInsideRoot(self.catalog:getCurrentDownloadDir(), path)
    then
        Toast.error("Only downloads inside your BookOrbit download folder can be removed here.")
        return
    end
    UIManager:show(ConfirmBox:new {
        text = "Remove this download from the Kobo? The server copy and local reading notes are kept.\n\n"
            .. book.title,
        ok_text = "Remove download",
        ok_callback = function()
            local ok = os.remove(path)
            if not ok then
                Toast.error("Could not remove this file.")
                return
            end
            StateManager.invalidate()
            self.catalog:refreshOnDevice()
            self:navigate({ kind = "books", filter = "local" }, true)
            self.plugin:requestSweep(false, "storage", { quiet = true })
        end,
    })
end

function Hub:turnPage(delta)
    local r, s = self.route, self.state
    if delta < 0 and not s.previous or delta > 0 and not s.next then
        return
    end
    local display_page = math.max(1, (r.displayPage or r.subpage or 1) + delta)
    if delta < 0 and (r.subpage or 1) > 1 or delta > 0 and (r.subpage or 1) * s.sliceSize < #(s.body.items or {}) then
        r.displayPage = display_page
        r.subpage = (r.subpage or 1) + delta
        r.scroll = nil
        self.state.scrolling = nil
        self:refreshView()
    else
        local next_route = copy(r)
        next_route.displayPage = display_page
        next_route.page = (r.page or 1) + delta
        next_route.subpage = delta < 0 and 999 or 1
        next_route.scroll = nil
        self:navigate(next_route, true)
    end
end

function Hub:action(a)
    local Roulette = require("bookorbit_roulette")
    if a.kind == "discover_more" then
        self:menu("Discover", {
            {
                text = "For You",
                callback = function()
                    self:navigate({ kind = "discover" })
                end,
            },
            {
                text = "Browse authors",
                callback = function()
                    self:prompt("author")
                end,
            },
            {
                text = "Browse series",
                callback = function()
                    self:prompt("series")
                end,
            },
            {
                text = "New releases",
                callback = function()
                    self:action({ kind = "new_releases" })
                end,
            },
            {
                text = "Friends: what other readers enjoy",
                callback = function()
                    self:navigate({ kind = "social" })
                end,
            },
            {
                text = "Your tastes",
                callback = function()
                    Roulette.tastes(self)
                end,
            },
        })
        return
    elseif a.kind == "stats" or a.kind == "social" or a.kind == "diagnostics" or a.kind == "hub_settings" then
        self:navigate({ kind = a.kind })
        return
    elseif a.kind == "finished_books" then
        self:navigate({ kind = "books", readStatus = "finished", sort = "recently_read", page = 1 })
        return
    elseif a.kind == "share_toggle" then
        local share = not (self.state.body and self.state.body.share)
        self:fetch("POST", ROOT .. "hub/social/sharing", { share = share }, function()
            Toast.show(share and "Sharing your reading with other readers" or "Sharing turned off")
            self:load(false)
        end)
        return
    elseif a.kind == "more_like_this" then
        local b = a.book or {}
        local seed = b.bookId and { bookId = b.bookId, title = b.title }
            or { title = b.title, author = (b.authors or {})[1], genre = (b.genres or {})[1] }
        self:navigate({ kind = "roulette", seed = seed })
        return
    elseif a.kind == "create_collection" then
        self:createCollection(nil)
        return
    elseif a.kind == "hub_option" then
        local settings = self.plugin.settings
        if Model.option(a.key) then
            settings[a.key] = Model.nextSetting(settings, a.key)
            G_reader_settings:flush()
            if a.key == "hub_charging_downloads" or a.key == "hub_cleanup_days" then
                require("bookorbit_hub_upkeep").soon(self.plugin, 5)
            end
            self:refreshView()
        end
        return
    elseif a.kind == "clear_cache" then
        UIManager:show(ConfirmBox:new {
            text = "Forget saved pages and downloaded covers? Books, notes and queued actions are kept.",
            ok_text = "Clear",
            ok_callback = function()
                ListCache.clear()
                local dir = self.catalog.thumbnail_cache_dir
                local removed = 0
                if dir and lfs.attributes(dir, "mode") == "directory" then
                    local doomed = {}
                    for name in lfs.dir(dir) do
                        if name:match("%.jpg$") then
                            doomed[#doomed + 1] = dir .. "/" .. name
                        end
                    end
                    for _, path in ipairs(doomed) do
                        if os.remove(path) then
                            removed = removed + 1
                        end
                    end
                end
                self.catalog:cancelThumbnailJobs()
                require("bookorbit_board_ui").clearCoverCache()
                Diag.event(self.plugin.settings, "info", "Cleared saved pages and " .. removed .. " covers")
                self:refreshView()
            end,
        })
        return
    elseif a.kind == "outbox_send" then
        Outbox.drain(self)
        Toast.show(NetworkMgr:isConnected() and "Sending saved actions…" or "Waiting for Wi-Fi")
        return
    elseif a.kind == "outbox_discard" then
        UIManager:show(ConfirmBox:new {
            text = "Discard " .. Outbox.count(self) .. " saved actions without sending them?",
            ok_text = "Discard",
            ok_callback = function()
                Outbox.clear(self)
                self:refreshView()
            end,
        })
        return
    elseif a.kind == "upkeep_now" then
        require("bookorbit_hub_upkeep").run(self.plugin, { force = true, report = true })
        return
    elseif a.kind == "resume_reading" then
        if self.plugin.ui and self.plugin.ui.document == self.resumeDocument then
            self:close()
        else
            Toast.show("The previous reading session is no longer open.")
        end
        return
    elseif a.kind == "roulette" or a.kind == "matches" then
        self:navigate({ kind = a.kind })
        return
    elseif a.kind == "roulette_decide" then
        Roulette.decide(self, a.decision, a.book)
        return
    elseif a.kind == "roulette_undo" then
        Roulette.undo(self)
        return
    elseif a.kind == "roulette_more" then
        Roulette.more(self)
        return
    elseif a.kind == "roulette_tastes" then
        Roulette.tastes(self)
        return
    elseif a.kind == "match_remove" then
        Roulette.decide(self, "remove", a.book)
        return
    elseif a.kind == "match_select" then
        self.selectingMatches = not self.selectingMatches
        self:refreshView()
        return
    elseif a.kind == "match_toggle" then
        self.selectedMatches = self.selectedMatches or {}
        local key = a.book.matchKey
        self.selectedMatches[key] = not self.selectedMatches[key] or nil
        self:refreshView()
        return
    elseif a.kind == "match_filters" then
        Roulette.filters(self)
        return
    elseif a.kind == "match_acquire" then
        local keys = {}
        for key in pairs(self.selectedMatches or {}) do
            keys[#keys + 1] = key
        end
        if #keys > 20 then
            Toast.error("Choose at most 20 matches at once.")
            return
        end
        UIManager:show(ConfirmBox:new {
            text = "Request "
                .. #keys
                .. " selected matches through your configured sources? Approval rules still apply.",
            ok_text = "Add to Library",
            ok_callback = function()
                Roulette.acquire(self, keys)
            end,
        })
        return
    end
    if a.kind == "tab" then
        self:savePosition()
        self.tabs[self.tab] = { route = self.route, state = self.state, history = self.history }
        local saved = a.tab ~= self.tab and self.tabs[a.tab]
        if saved then
            self.route, self.state, self.history, self.tab = saved.route, saved.state, saved.history, a.tab
            self:refreshView()
            if self.route.kind == "requests" then
                self:load(true)
            end
        else
            self:navigate({ kind = a.tab, page = 1 }, true)
        end
    elseif a.kind == "search" then
        self:prompt()
    elseif a.kind == "refresh" then
        if self.route.kind == "books" and self.route.filter == "local" then
            self:localBooks()
            self:refreshView()
        else
            self:load(false)
        end
    elseif a.kind == "settings" then
        self:navigate({ kind = "settings" })
    elseif a.kind == "setting" then
        self.plugin:openSettings(self.catalog, a.view)
    elseif a.kind == "update" then
        self.plugin:applyUpdate(self.plugin.settings.update_latest_version)
    elseif a.kind == "sync_now" then
        self.plugin:startSweep()
    elseif a.kind == "classic" then
        self:close()
        self.plugin:openClassicCatalogBrowser(false)
    elseif a.kind == "close_hub" then
        self:close()
    elseif a.kind == "filters" then
        require("bookorbit_hub_filters").open(self)
    elseif a.kind == "genre_list" then
        self:navigate({ kind = "genre_list" })
    elseif a.kind == "library_author" then
        self:navigate({ kind = "books", author = a.name })
    elseif a.kind == "book" then
        self:openBook(a.book)
    elseif a.kind == "primary" then
        self:primary(a.book)
    elseif a.kind == "page" then
        self:turnPage(a.delta)
    elseif a.kind == "scope" then
        local r = copy(self.route)
        r.scope, r.page, r.subpage, r.scroll, r.displayPage = a.scope, 1, 1, nil, 1
        self:navigate(r, true)
    elseif a.kind == "request_filter" then
        self:navigate({ kind = "requests", filter = a.filter, page = 1 }, true)
    elseif a.kind == "books_filter" then
        self:navigate({ kind = "books", filter = a.filter, page = 1 })
    elseif a.kind == "author_prompt" then
        self:prompt("author")
    elseif a.kind == "author" and a.q then
        self:navigate({ kind = "browse", mode = "author", q = a.q, page = 1 })
    elseif a.kind == "genre" then
        self:navigate({ kind = "browse", mode = "subject", q = a.q, page = 1 })
    elseif a.kind == "new_releases" then
        self:navigate({ kind = "browse", mode = "subject", sort = "new", q = "Fiction", page = 1 })
    elseif a.kind == "series_list" then
        self:navigate({ kind = "series_list", page = 1 })
    elseif a.kind == "series_prompt" then
        self:prompt("series")
    elseif a.kind == "series" and a.q then
        self:navigate({ kind = "series", q = a.q, author = a.book and a.book.authors[1] })
    elseif a.kind == "wishlist" or a.kind == "collections" then
        self:navigate({ kind = a.kind, page = 1 })
    elseif a.kind == "collection" then
        self:navigate({ kind = "books", collectionId = a.collection.id, page = 1 })
    elseif a.kind == "book_options" then
        self:bookOptions(a.book)
    elseif a.kind == "save_wishlist" and not NetworkMgr:isConnected() then
        local b = a.book
        local key = b.wishlistKey
        self:queue({
            method = key and "DELETE" or "POST",
            path = ROOT .. "hub/wishlist" .. (key and "/" .. key or ""),
            payload = not key and Model.wishlist(b) or nil,
            label = (key and "Remove from Wishlist: " or "Wishlist: ") .. tostring(b.title),
            kind = "wishlist",
            key = "wishlist:" .. tostring(b.title) .. "|" .. tostring((b.authors or {})[1]),
        })
    elseif a.kind == "save_wishlist" then
        local b = a.book
        self:fetch(
            b.wishlistKey and "DELETE" or "POST",
            ROOT .. "hub/wishlist" .. (b.wishlistKey and "/" .. b.wishlistKey or ""),
            not b.wishlistKey and Model.wishlist(b) or nil,
            function(body)
                self.state.body.wishlistKey = body.key
                self.route.book.wishlistKey = body.key
                self:refreshView()
                Toast.show(body.key and "Saved to Wishlist" or "Removed from Wishlist")
            end
        )
    elseif a.kind == "editions" then
        self:editions(a.book, 1)
    elseif a.kind == "genres" then
        local rows = {}
        for _, name in ipairs(a.book.genres or {}) do
            local q = name
            rows[#rows + 1] = {
                text = q,
                callback = function()
                    self:action({ kind = "genre", q = q })
                end,
            }
        end
        if #rows == 0 then
            rows[1] = { text = "No genres supplied. Browse this author or Discover." }
        end
        self:menu("Related genres", rows)
    elseif a.kind == "storage" then
        self:navigate({ kind = "books", filter = "local" })
    elseif a.kind == "sync_status" then
        self.plugin:openSyncStatus()
    elseif a.kind == "swap" then
        self.catalog:loadReplacement(a.bookId, a.previousBookId)
    elseif a.kind == "request_series" then
        local choices = Model.seriesActions(self.state.body)
        if not choices.complete or #choices.missing == 0 then
            return
        end
        UIManager:show(ConfirmBox:new {
            text = "Request "
                .. #choices.missing
                .. " numbered missing volumes? Existing approval and acquisition rules apply.",
            ok_text = "Request volumes",
            ok_callback = function()
                local books = {}
                for _, b in ipairs(choices.missing) do
                    books[#books + 1] = Model.requestPayload(b)
                end
                self:fetch("POST", ROOT .. "discovery/requests", { books = books }, function(body)
                    local failed = 0
                    for _, result in ipairs(body.items or body.results or {}) do
                        if result.error or result.statusCode then
                            failed = failed + 1
                        end
                    end
                    Toast.show(
                        failed > 0 and (failed .. " requests need attention. Check Requests.") or "Requests submitted"
                    )
                    self:navigate({ kind = "requests" })
                end)
            end,
        })
    elseif a.kind == "download_series" then
        local choices = Model.seriesActions(self.state.body)
        self.catalog:confirmBulkBooks(choices.owned, self.route.q, { preserve_order = true })
    elseif a.kind == "releases" then
        self:navigate({ kind = "releases", id = self.route.id, request = self.state.body, page = 1 })
    elseif a.kind == "discard_held" and self.state.body.canDiscardHeld then
        local id = self.route.id
        UIManager:show(ConfirmBox:new {
            text = "Discard the held download so another release can be tried?",
            ok_text = "Discard held file",
            ok_callback = function()
                self:fetch("POST", ROOT .. "requests/" .. id .. "/discard-held", {}, function(body)
                    self.state.body = body
                    self:refreshView()
                end)
            end,
        })
    elseif a.kind == "replace_request" and self.state.body.canReplace then
        self:changeFile(self.state.book, self.state.body)
    elseif a.kind == "retry" or a.kind == "cancel_request" then
        local request = self.state.body
        if a.kind == "retry" and not request.canRetry or a.kind == "cancel_request" and not request.canCancel then
            return
        end
        local run = function()
            self:fetch(
                "POST",
                ROOT .. "requests/" .. request.id .. (a.kind == "retry" and "/retry" or "/cancel"),
                {},
                function(body)
                    self.state.body = body
                    self:refreshView()
                end
            )
        end
        if a.kind == "cancel_request" then
            UIManager:show(ConfirmBox:new { text = "Cancel this request?", ok_callback = run })
        else
            run()
        end
    elseif a.kind == "grab" then
        local release = a.release
        UIManager:show(ConfirmBox:new {
            text = release.title
                .. "\n"
                .. (release.language or "Unknown language")
                .. " · "
                .. (release.format or "Unknown format")
                .. "\n\nDownload this authorized release through BookOrbit?",
            ok_text = "Download release",
            ok_callback = function()
                self:fetch(
                    "POST",
                    ROOT .. "requests/" .. self.route.id .. "/grab",
                    { releaseId = release.releaseId },
                    function(body)
                        self:navigate({ kind = "request_detail", id = body.id, request = body })
                    end
                )
            end,
        })
    end
end

function Hub.open(plugin, offline, initial)
    if plugin._bookorbit_hub then
        if initial then
            plugin._bookorbit_hub:navigate(initial)
        end
        return plugin._bookorbit_hub
    end
    if plugin.catalog_browser then
        local previous = plugin.catalog_browser
        if previous.close_callback then
            previous.close_callback()
        else
            UIManager:close(previous)
            plugin.catalog_browser = nil
        end
    end
    local api = plugin:apiOpts(true)
    local self = setmetatable({
        plugin = plugin,
        client = Api.new(api),
        account = md5(table.concat({ api.server_url, api.username, api.userkey }, "|")),
        history = {},
        tabs = {},
        tab = "home",
        visibleCovers = {},
    }, Hub)
    self.catalog = Catalog:new {
        api = api,
        settings = plugin.settings,
        path = plugin.path,
        headless = true,
        _manager = plugin,
        save_settings = function()
            G_reader_settings:flush()
        end,
        updateItems = function()
            self:coversArrived()
        end,
        showBookDetail = function(_, detail)
            self:openBook(Model.book(detail))
        end,
        onCloseAllMenus = function()
            self:close()
        end,
        goDashboard = function()
            self:navigate({ kind = "home" }, true)
        end,
        close_callback = function()
            self:close()
        end,
    }
    local remembered = plugin.settings.hub_navigation
    if not offline and remembered and remembered.account == self.account then
        self.tab = remembered.tab or "home"
    end
    local route = initial
        or (not offline and remembered and remembered.account == self.account and remembered.route)
        or { kind = "home" }
    -- Detail records are intentionally not persisted; opening again uses their parent tab.
    if
        not ({
            home = true,
            discover = true,
            books = true,
            requests = true,
            search = true,
            wishlist = true,
            collections = true,
            series_list = true,
            browse = true,
            author_list = true,
            genre_list = true,
            roulette = true,
            matches = true,
            stats = true,
            social = true,
        })[route.kind]
    then
        route = { kind = remembered and remembered.tab or "home" }
    end
    self.resumeDocument = plugin.ui and plugin.ui.document
    self.route, self.state = route, { route = route, body = {}, tab = "home" }
    self:present()
    self.page = MenuPage:new {
        build = function(page, w, h)
            local widget = View.build(self.state, w, h)
            -- ScrollableContainer marks its top-level owner dirty on every scroll.
            if self.state.scrolling then
                self.state.scrolling.show_parent = page
            end
            return widget
        end,
        on_action = function(_, action)
            Diag.guard(self, "action " .. tostring(action.kind), function()
                self:action(action)
            end)
        end,
        on_back = function()
            self:back()
            return true
        end,
        on_close = function()
            self:close()
        end,
        on_page_key = function(_, delta)
            self:turnPage(delta)
            return true
        end,
        on_swipe = function(_, ges)
            if View.isList(self.route.kind) then
                if ges.direction == "west" then
                    self:turnPage(1)
                elseif ges.direction == "east" then
                    self:turnPage(-1)
                end
                return true
            end
        end,
        loadBookDetail = function(_, id)
            self:openBook({ bookId = id, title = "Book", authors = {} })
        end,
        loadReplacement = function(_, ...)
            self.catalog:loadReplacement(...)
        end,
        setApi = function(_, next_api)
            local key =
                md5(table.concat({ next_api.server_url or "", next_api.username or "", next_api.userkey or "" }, "|"))
            if key ~= self.account then
                self:close()
            else
                self.catalog:setApi(next_api)
            end
        end,
        refreshCurrent = function()
            self:load(true)
        end,
        onResume = function()
            if not self.closed then
                self:load(true)
                self:scheduleWatch(true, 3)
            end
        end,
        onDeviceBookPath = function(_, b)
            return self.catalog:onDeviceBookPath(b)
        end,
        confirmBulkBooks = function(_, ...)
            return self.catalog:confirmBulkBooks(...)
        end,
        dashboardMode = function()
            return self.route.kind == "home"
        end,
        loadDashboardRoot = function()
            self:load(true)
        end,
        markStackDirty = function()
            self.localMetadata = nil
            self.catalog:refreshOnDevice()
            self:refreshView()
        end,
    }
    -- ScrollableContainer paints native hit areas at their real scrolled
    -- coordinates. Crop those areas too, so hidden rows cannot steal nav taps.
    self.page.paintTo = function(page, bb, x, y)
        local focus = page.focus_index
        page.focus_index = nil
        MenuPage.paintTo(page, bb, x, y)
        local bounds = self.state.bodyBounds
        for i = self.state.bodyHitFirst or 1, self.state.bodyHitLast or 0 do
            local hit = page.hits[i]
            local d = hit and hit.dimen
            if d then
                local left, top = math.max(d.x, bounds.x), math.max(d.y, bounds.y)
                local right, bottom = math.min(d.x + d.w, bounds.x + bounds.w), math.min(d.y + d.h, bounds.y + bounds.h)
                hit.dimen = right > left
                        and bottom > top
                        and Geom:new { x = left, y = top, w = right - left, h = bottom - top }
                    or nil
            end
        end
        page.focus_index = focus
        local hit = focus and page.hits[focus]
        if hit and hit.dimen then
            local d = hit.dimen
            bb:paintBorder(d.x, d.y, d.w, d.h, Theme.px(2), Theme.ink.black)
        end
    end
    -- Saved pages are written before the Kobo sleeps, not on every refresh.
    self.page.onSuspend = function()
        ListCache.flush()
        G_reader_settings:flush()
    end
    self.page.onNetworkConnected = function()
        if not self.closed then
            Outbox.drain(self)
            self:scheduleWatch(true, 3)
        end
    end
    plugin._bookorbit_hub, plugin.catalog_browser = self, self.page
    UIManager:show(self.page)
    self:navigate(route, true, offline)
    -- Catch requests that finished while BookOrbit was closed.
    self:scheduleWatch(true, 3)
    Outbox.retryLater(self, 4)
    require("bookorbit_hub_upkeep").soon(plugin, 20)
    return self
end

return Hub
