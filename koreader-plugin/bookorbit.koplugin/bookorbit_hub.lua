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
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local Hub = {}
Hub.__index = Hub
local ROOT = "/koreader/plugin/"
-- Request watching: delays between checks while BookOrbit is open, and how long
-- a request may go without any change before this Kobo stops following it.
local WATCH_DELAYS = { 15, 30, 60, 120, 300 }
local WATCH_STALE_SECONDS = 7 * 24 * 3600

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
    if self.watchTimer then
        UIManager:unschedule(self.watchTimer)
        self.watchTimer = nil
    end
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

function Hub:refreshView()
    if self.closed or not self.page then
        return
    end
    if self.state and self.state.scrolling then
        self.route.scroll = self.state.scrolling:getScrolledOffset()
    end
    self:present()
    self.page:refresh()
    self.page.cropping_widget = self.state.scrolling
    self.catalog:scheduleThumbnailDownloads(self.visibleCovers)
end

function Hub:prepare(raw, request)
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
        self.visibleCovers[#self.visibleCovers + 1] = b
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
        s.recommendations, s.continueReading, s.requests = {}, {}, {}
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
        s.book = body.items and body.items[1] and self:prepare(body.items[1]) or nil
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

function Hub:path(r)
    local page = tostring(r.page or 1)
    local extra = ""
    for _, key in ipairs({ "language", "genre", "sort", "refine" }) do
        if r[key] then
            extra = extra .. "&" .. key .. "=" .. Model.encode(r[key])
        end
    end
    if r.kind == "roulette" then
        return ROOT .. "roulette"
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
        local cached = ListCache.get(self.account .. "|hub|" .. path)
        if cached then
            self.state.body = cached.body
            self.state.cached = true
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

function Hub:load(offline)
    local route, path = self.route, self:path(self.route)
    if not path then
        self:refreshView()
        return
    end
    self:fetch("GET", path, nil, function(body)
        if route.kind == "detail" then
            local merged = copy(route.book)
            for key, value in pairs(body) do
                merged[key] = value
            end
            body = merged
        end
        self.state.body, self.state.cached, self.state.error = body, false, nil
        ListCache.put(self.account .. "|hub|" .. path, body)
        if route.kind == "request_detail" then
            route.request = body
            self:observe({ body })
        elseif route.kind == "requests" then
            self:observe(body.items or {})
        elseif route.kind == "home" then
            self:observe(body.requests or {})
        end
        self:refreshView()
    end, offline)
end

function Hub:fetch(method, path, payload, done, offline)
    if self.closed then
        return
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
        self.pendingFetch = { method, path, payload, done, offline, route = self.route }
        if not self.state.loading then
            self.state.loading = true
            self:refreshView()
        end
        return
    end
    if not NetworkMgr:isConnected() then
        self.state.error = "Offline · Downloaded books are available in My Books"
        self:refreshView()
        if not offline then
            NetworkMgr:runWhenConnected(function()
                if not self.closed then
                    self:fetch(method, path, payload, done, true)
                end
            end)
        end
        return
    end
    local route = self.route
    self.activeFetch = { method = method, path = path, route = route }
    self.busy = true
    self.state.loading = true
    self:refreshView()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local completed, result = self.client:runInSubprocess(function()
                return self.client:requestBlocking(method, path, payload)
            end)
            self.busy = false
            self.activeFetch = nil
            if self.closed then
                return
            end
            local settings = self.plugin.settings
            if
                self.account
                ~= md5(
                    table.concat({ settings.server_url or "", settings.username or "", settings.userkey or "" }, "|")
                )
            then
                self:close()
                return
            end
            if route == self.route then
                self.state.loading = false
                if completed and result and result.body then
                    done(result.body)
                else
                    self.state.error =
                        Model.errorText(method, completed, result and result.err, result and result.errbody)
                    if method ~= "GET" then
                        Toast.error(self.state.error)
                    end
                    self:refreshView()
                end
            end
            local pending = self.pendingFetch
            self.pendingFetch = nil
            if pending and pending.route == self.route then
                self:fetch(pending[1], pending[2], pending[3], pending[4], pending[5])
            end
        end)
    end)
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

-- One small request for the newest requests. Status changes move a request to
-- the top of that list, so the first page is enough. Never turns on Wi-Fi.
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
    if next(items) == nil then
        return
    end
    if self.busy or not NetworkMgr:isConnected() then
        self:scheduleWatch(false, self.busy and 3 or nil)
        return
    end
    self.watchStep = (self.watchStep or 1) + 1
    local path = ROOT .. "requests?page=1&filter=all"
    self:quietGet(path, function(body)
        local list = body.items or {}
        self:observe(list)
        self:showWatchedChanges(path, body, list)
        self:scheduleWatch(false)
    end)
end

-- Repaints only the open request screen, and only when something visible changed.
function Hub:showWatchedChanges(path, body, list)
    local route, state = self.route, self.state
    local function signature(r)
        return tostring(r.status) .. ":" .. tostring(r.progressPercent)
    end
    if route.kind == "request_detail" then
        for _, r in ipairs(list) do
            if tostring(r.id) == tostring(route.id) and signature(r) ~= signature(state.body or {}) then
                route.request, state.body = r, r
                self:refreshView()
            end
        end
    elseif route.kind == "requests" and self:path(route) == path then
        local before, after = {}, {}
        for _, r in ipairs((state.body or {}).items or {}) do
            before[#before + 1] = tostring(r.id) .. signature(r)
        end
        for _, r in ipairs(list) do
            after[#after + 1] = tostring(r.id) .. signature(r)
        end
        if table.concat(before, ",") ~= table.concat(after, ",") then
            state.body = body
            ListCache.put(self.account .. "|hub|" .. path, body)
            self:refreshView()
        end
    end
end

-- A background GET: no loading notice, no error notice, no Wi-Fi prompt.
-- Actions tapped meanwhile wait in pendingFetch and run when it finishes.
function Hub:quietGet(path, done)
    self.busy = true
    self.activeFetch = { method = "GET", path = path, route = self.route, quiet = true }
    Trapper:wrap(function()
        local completed, result = self.client:runInSubprocess(function()
            return self.client:requestBlocking("GET", path)
        end)
        self.busy = false
        self.activeFetch = nil
        if self.closed then
            return
        end
        local settings = self.plugin.settings
        if
            self.account
            ~= md5(table.concat({ settings.server_url or "", settings.username or "", settings.userkey or "" }, "|"))
        then
            self:close()
            return
        end
        if completed and result and result.body then
            done(result.body)
        else
            self:scheduleWatch(false)
        end
        local pending = self.pendingFetch
        self.pendingFetch = nil
        if pending and pending.route == self.route then
            self:fetch(pending[1], pending[2], pending[3], pending[4], pending[5])
        end
    end)
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
    else
        self:fetch("POST", ROOT .. "requests", Model.requestPayload(book), function(body)
            self:navigate({ kind = "request_detail", id = body.request.id, request = body.request })
        end)
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
    self:fetch("GET", ROOT .. "hub/collections?bookId=" .. book.bookId .. "&page=" .. page, nil, function(body)
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
        if #rows == 0 then
            rows[1] = { text = "No editable collections. Create a collection in BookOrbit." }
        end
        if body.hasMore then
            rows[#rows + 1] = {
                text = "More collections",
                callback = function()
                    self:collectionPicker(book, page + 1)
                end,
            }
        end
        self:menu("Your collections", rows)
    end)
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
                text = "Your tastes",
                callback = function()
                    Roulette.tastes(self)
                end,
            },
        })
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
            if
                self.route
                and self.route.kind == "books"
                and self.route.filter == "local"
                and self.localListGeneration ~= self.catalog.on_device_generation
            then
                self:localBooks()
            end
            self:refreshView()
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
            self:action(action)
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
    plugin._bookorbit_hub, plugin.catalog_browser = self, self.page
    UIManager:show(self.page)
    self:navigate(route, true, offline)
    -- Catch requests that finished while BookOrbit was closed.
    self:scheduleWatch(true, 3)
    return self
end

return Hub
