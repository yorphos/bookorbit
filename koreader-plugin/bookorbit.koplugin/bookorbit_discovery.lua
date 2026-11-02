-- Public metadata is fetched by BookOrbit; acquisition and credentials stay on the server.
local Requests = require("bookorbit_requests")
local Api = require("bookorbit_api")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")
local Discovery = setmetatable({}, { __index = Requests })
Discovery.__index = Discovery
local ROOT = "/koreader/plugin/discovery"
local function encode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function Discovery:home()
    self:show(_("Discover and request books"), {
        {text = _("Search library and catalogs"), callback = function() self:searchFields() end},
        {text = _("Discover books / Genres"), callback = function() self:genres() end},
        {text = _("Browse an author"), callback = function() self:promptDiscovery("author", "browse") end},
        {text = _("Series / Continue series"), callback = function() self:promptDiscovery("series", "series") end},
        {text = _("Request and download inbox"), callback = function() self:inbox() end},
        {text = _("Ready to Read"), callback = function() self:list(1, "ready") end},
        {text = _("Browse my library"), callback = function() self:close(); self.plugin:openBookOrbit() end},
    })
end

function Discovery:searchFields()
    local rows = {{text = _("Back"), callback = function() self:home() end}}
    for _i, field in ipairs({"title", "author", "series", "isbn"}) do
        local choice = field
        table.insert(rows, {text = _("Search by ") .. field, callback = function() self:promptDiscovery(choice, "search") end})
    end
    self:show(_("Universal search"), rows)
end

function Discovery:promptDiscovery(field, mode)
    local dialog
    dialog = InputDialog:new{title = _("Search by ") .. field, input = "", buttons = {{
        {text = _("Cancel"), callback = function() UIManager:close(dialog) end},
        {text = _("Search"), is_enter_default = true, callback = function()
            local query = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
            if #query < 2 then return end
            UIManager:close(dialog)
            if mode == "series" then self:series(query) else self:results(query, field, mode, 1) end
        end},
    }}}
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Discovery:bookLabel(book)
    local a = book.availability or {}
    local label = _("Available to request")
    if a.ownedBookId then
        label = _("In library / Ready to download")
        local catalog = self.plugin.catalog_browser
        if catalog and catalog.onDeviceBookPath and catalog:onDeviceBookPath({id = a.ownedBookId}) then label = _("Downloaded on this Kobo") end
    elseif a.existingRequestId then label = Requests.statusText({status = a.existingRequestStatus}) end
    local index = book.seriesIndex and (tostring(book.seriesIndex) .. ". ") or ""
    return index .. book.title .. "\n" .. table.concat(book.authors or {}, ", ") .. " | " .. label
end

function Discovery:results(query, field, mode, page)
    local path = ROOT .. (mode == "browse" and "/browse?mode=" or "/search?field=") .. field .. "&q=" .. encode(query) .. "&page=" .. page
    self:fetch("GET", path, nil, function(body)
        local back = function() self:results(query, field, mode, page) end
        local rows = {{text = _("Back to discovery"), callback = function() self:home() end}}
        if body.partial or body.limited then table.insert(rows, {text = _("Some sources returned limited results. Refine your search if needed.")}) end
        for _i, book in ipairs(body.items or {}) do
            local item = book
            table.insert(rows, {text = self:bookLabel(item), callback = function() self:book(item, back) end})
        end
        if #(body.items or {}) == 0 then table.insert(rows, {text = _("No matches. Try another title or author.")}) end
        if page > 1 then table.insert(rows, {text = _("Previous page"), callback = function() self:results(query, field, mode, page - 1) end}) end
        if body.hasMore then table.insert(rows, {text = _("Next page"), callback = function() self:results(query, field, mode, page + 1) end}) end
        self:show(query .. " / " .. page, rows)
    end)
end

function Discovery:book(book, back)
    local a = book.availability or {}
    local rows = {
        {text = _("Back"), callback = back or function() self:home() end},
        {text = self:bookLabel(book)},
        {text = a.ownedBookId and _("Download / Read") or a.existingRequestId and _("View / Join request") or _("Request English EPUB"), callback = function() self:select(book) end},
    }
    if book.language then table.insert(rows, {text = _("Catalog language: ") .. book.language}) end
    if book.formats and #book.formats > 0 then table.insert(rows, {text = _("Library formats: ") .. table.concat(book.formats, ", ")}) end
    if book.isbn13 then table.insert(rows, {text = "ISBN: " .. book.isbn13}) end
    if book.description and book.description ~= "" then table.insert(rows, {text = _("Description"), callback = function()
        require("bookorbit_text_pages").about({title = book.title, authors = book.authors}, book.description)
    end}) end
    if book.providerKey == "openLibrary" and (book.providerId or ""):match("^OL%d+W$") then
        table.insert(rows, {text = _("Details / Editions / Languages"), callback = function() self:editions(book, back, 1) end})
    end
    if book.coverUrl or book.providerKey == "openLibrary" then table.insert(rows, {text = _("View cover"), callback = function() self:cover(book) end}) end
    for _i, name in ipairs(book.authors or {}) do
        local author = name
        table.insert(rows, {text = _("More by ") .. author, callback = function() self:results(author, "author", "browse", 1) end})
    end
    if book.seriesName then table.insert(rows, {text = _("Series: ") .. book.seriesName, callback = function() self:series(book.seriesName, book.authors and book.authors[1]) end}) end
    for i, name in ipairs(book.genres or {}) do
        if i > 5 then break end
        local genre = name
        table.insert(rows, {text = _("Related: ") .. genre, callback = function() self:results(genre, "subject", "browse", 1) end})
    end
    self:show(book.title, rows)
end

function Discovery:editions(book, back, page)
    self:fetch("GET", ROOT .. "/works/" .. book.providerId .. "?page=" .. page, nil, function(body)
        if body.description then book.description = body.description end
        if body.genres then book.genres = body.genres end
        local rows = {{text = _("Back to book / Description"), callback = function() self:book(book, back) end},
            {text = _("Catalog editions may be print editions. Actual ebook formats and availability are checked by BookOrbit when requested.")}}
        for _i, edition in ipairs(body.editions or {}) do
            table.insert(rows, {text = (edition.title or book.title) .. "\n" .. table.concat(edition.languages or {}, ", ") .. " / " .. (edition.format or _("Unknown format")) .. " / " .. (edition.publisher or "") .. " " .. (edition.date or "")})
        end
        if page > 1 then table.insert(rows, {text = _("Previous editions"), callback = function() self:editions(book, back, page - 1) end}) end
        if body.hasMore then table.insert(rows, {text = _("More editions"), callback = function() self:editions(book, back, page + 1) end}) end
        self:show(_("Editions"), rows)
    end)
end

function Discovery:cover(book)
    if self.busy then return end
    self.busy = true
    local generation = self.generation
    require("ui/network/manager"):runWhenConnected(function()
        require("ui/trapper"):wrap(function()
            local path = require("datastorage"):getDataDir() .. "/cache/bookorbit-discovery-cover.jpg"
            local completed, result = self.client:runInSubprocess(function()
                local endpoint = book.providerKey == "openLibrary" and (ROOT .. "/works/" .. book.providerId .. "/cover") or (ROOT .. "/cover?url=" .. encode(book.coverUrl))
                return self.client:downloadBlocking(endpoint, path, {max_bytes = 2000000})
            end)
            self.busy = false
            if self.closed or self.generation ~= generation then return end
            if completed and result and result.body then
                UIManager:show(require("ui/widget/imageviewer"):new{file = path, title_text = book.title, fullscreen = true})
            else self:message(_("Cover unavailable. Please try again later.")) end
        end)
    end)
end

function Discovery:genres()
    local rows = {{text = _("Back"), callback = function() self:home() end},
        {text = _("Browse another genre"), callback = function() self:promptDiscovery("subject", "browse") end},
        {text = _("Popular in each genre; recommendations are based on catalog subjects.")}}
    for _i, name in ipairs({"Science fiction", "Fantasy", "Mystery", "Romance", "Historical fiction", "Classics", "Adventure", "Biography", "Science", "History"}) do
        local genre = name
        table.insert(rows, {text = genre, callback = function() self:results(genre, "subject", "browse", 1) end})
    end
    self:show(_("Discover beyond my library"), rows)
end

function Discovery:inbox()
    local rows = {{text = _("Back"), callback = function() self:home() end}}
    for _i, entry in ipairs({{"all", _("All requests")}, {"pending", _("Waiting for approval")}, {"processing", _("Searching / Downloading / Importing")}, {"ready", _("Ready to Read")}, {"failed", _("Failed / Cancelled / Rejected")}}) do
        local filter, label = entry[1], entry[2]
        table.insert(rows, {text = label, callback = function() self:list(1, filter) end})
    end
    self:show(_("Request and download inbox"), rows)
end

function Discovery:series(query, author)
    self:fetch("GET", ROOT .. "/series?q=" .. encode(query) .. (author and ("&author=" .. encode(author)) or ""), nil, function(body)
        self:seriesPage(query, author, body, 1)
    end)
end

function Discovery:seriesPage(query, author, body, page)
    local back = function() self:seriesPage(query, author, body, page) end
    local rows = {{text = _("Back"), callback = function() self:home() end}, {text = _("Refresh series"), callback = function() self:series(query, author) end}}
    if body.partial or body.truncated then table.insert(rows, {text = _("Incomplete catalog snapshot. Bulk requests are disabled; request individual books or narrow by author.")}) end
    if body.gaps and #body.gaps > 0 then table.insert(rows, {text = _("No catalog record for volume numbers: ") .. table.concat(body.gaps, ", ")}) end
    if not body.orderingComplete then table.insert(rows, {text = _("Some volume numbers are unknown. Bulk actions include numbered volumes only; select other editions individually.")}) end
    local missing, downloadable = {}, {}
    for _i, book in ipairs(body.items or {}) do
        local a = book.availability or {}
        if not a.ownedBookId and not a.existingRequestId and book.seriesIndex ~= nil then table.insert(missing, book) end
        if a.ownedBookId and book.seriesIndex ~= nil then table.insert(downloadable, {id = a.ownedBookId, title = book.title, authors = book.authors, seriesIndex = book.seriesIndex}) end
    end
    if body.next and body.orderingComplete and not body.partial and not body.truncated then table.insert(rows, {text = _("Continue series: ") .. body.next.title, callback = function() self:book(body.next, back) end}) end
    if #missing > 0 and not body.partial and not body.truncated then table.insert(rows, {text = _("Request missing numbered volumes (") .. #missing .. ")", callback = function() self:requestSeries(missing) end}) end
    if #downloadable > 0 then table.insert(rows, {text = _("Download numbered volumes in reading order (") .. #downloadable .. ")", callback = function()
        self:close(); self.plugin:browseCatalog(false)
        UIManager:nextTick(function()
            local catalog = self.plugin.catalog_browser
            if catalog then catalog:confirmBulkBooks(downloadable, query, {preserve_order = true}) end
        end)
    end}) end
    for index = (page - 1) * 15 + 1, math.min(page * 15, #(body.items or {})) do
        local book = body.items[index]
        table.insert(rows, {text = self:bookLabel(book), callback = function() self:book(book, back) end})
    end
    if page > 1 then table.insert(rows, {text = _("Previous volumes"), callback = function() self:seriesPage(query, author, body, page - 1) end}) end
    if page * 15 < #(body.items or {}) then table.insert(rows, {text = _("More volumes"), callback = function() self:seriesPage(query, author, body, page + 1) end}) end
    self:show(query .. " / " .. page, rows)
end

function Discovery:requestSeries(books)
    UIManager:show(ConfirmBox:new{text = _("Request all ") .. #books .. _(" missing numbered volumes in English? Your normal approval permissions apply. Catalog membership may include collected or companion editions; review the volume list first."), ok_text = _("Request missing books"), ok_callback = function()
        local payload = {}
        for _i, book in ipairs(books) do table.insert(payload, Requests.requestPayload(book)) end
        self:fetch("POST", ROOT .. "/requests", {books = payload}, function(body)
            local failed = 0
            for _i, result in ipairs(body.results or {}) do if result.error then failed = failed + 1 end end
            self:list(1)
            if failed > 0 then self:message(tostring(failed) .. _(" requests could not be saved. The others are in your inbox.")) end
        end)
    end})
end

function Discovery.open(plugin)
    local self = setmetatable({plugin = plugin, client = Api.new(plugin:apiOpts(true)), generation = 0}, Discovery)
    self:fetch("GET", "/options", nil, function(options) self.automaticApproval = options.automaticApproval; self:home() end)
    return self
end
return Discovery
