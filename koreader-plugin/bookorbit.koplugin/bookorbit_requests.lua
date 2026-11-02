-- Acquisition stays on BookOrbit. This screen only sends book metadata and follows the user's requests.
local Api = require("bookorbit_api")
local Device = require("device")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Requests = {}
Requests.__index = Requests

local status_labels = {
    pending = _("Waiting for administrator approval"), approved = _("Approved; looking for a release"),
    searching = _("Searching sources"), grabbed = _("Download queued"), downloading = _("Downloading"),
    importing = _("Importing into library"), needs_review = _("Administrator review needed"),
    available = _("Ready to read"), failed = _("Acquisition failed; check BookOrbit"),
    rejected = _("Request rejected"), cancelled = _("Request cancelled"),
}

local function encode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function Requests.statusText(request)
    local text = status_labels[request.status] or tostring(request.status or "")
    if request.status == "downloading" and tonumber(request.progressPercent) then
        text = text .. string.format(" (%d%%)", math.floor(request.progressPercent))
    end
    return text
end

function Requests:message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Requests:close()
    if self.watch_timer then UIManager:unschedule(self.watch_timer); self.watch_timer = nil end
    self.closed = true
    self.generation = (self.generation or 0) + 1
    if self.menu then UIManager:close(self.menu); self.menu = nil end
end

function Requests:show(title, items)
    self.detail_key = nil
    if self.watch_timer then UIManager:unschedule(self.watch_timer); self.watch_timer = nil end
    if self.closed then return end
    if self.menu then UIManager:close(self.menu) end
    self.menu = Menu:new{
        title = title, item_table = items, items_max_lines = 3,
        width = Device.screen:getWidth(), height = Device.screen:getHeight(),
        onMenuSelect = function(_, item)
            if item.callback and not self.busy then item.callback() end
            return true
        end,
        close_callback = function() self:close() end,
    }
    UIManager:show(self.menu)
end

function Requests:fetch(method, path, payload, callback, quiet)
    if self.busy or self.closed then return end
    self.busy = true
    self.generation = (self.generation or 0) + 1
    local generation = self.generation
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            if self.closed or generation ~= self.generation then self.busy = false; return end
            local wait = not quiet and InfoMessage:new{ text = _("Contacting BookOrbit...") } or nil
            if wait then UIManager:show(wait) end
            local completed, result = self.client:runInSubprocess(function()
                return self.client:request(method, (path:find("/koreader/", 1, true) == 1 and path or "/koreader/plugin/requests" .. path), payload)
            end, wait)
            if wait then UIManager:close(wait) end
            self.busy = false
            if self.closed or generation ~= self.generation then return end
            if not completed or not result or not result.body then
                local code = result and result.err
                local text = _("Could not complete the request. Check Wi-Fi and try again.")
                if code == 401 then text = _("Reconnect your BookOrbit account in Settings.")
                elseif code == 403 then text = _("Your account does not have permission to request books.")
                elseif code == 400 then text = _("The request or release changed. Refresh its status before trying again.")
                elseif type(code) == "number" and code >= 500 then text = _("BookOrbit or a catalog source is temporarily unavailable. Try again later. Downloaded books remain available offline.")
                elseif code == 404 then text = _("This BookOrbit server does not support device requests. Update the server.") end
                if method == "POST" then
                    text = text .. "\n" .. _("The request may have been saved. Check My requests before submitting again.")
                end
                self:message(text)
                return
            end
            callback(result.body)
        end)
    end)
end

function Requests:home()
    self:show(_("Find and request books"), {
        { text = _("Search by title"), callback = function() self:prompt("title") end },
        { text = _("Search by author"), callback = function() self:prompt("author") end },
        { text = _("My requests"), callback = function() self:list(1) end },
        { text = _("Browse my library"), callback = function() self:close(); self.plugin:openBookOrbit() end },
    })
end

function Requests:prompt(field)
    local dialog
    local function submit()
        local query = dialog:getInputText():match("^%s*(.-)%s*$")
        if #query < 2 then self:message(_("Enter at least two characters.")); return end
        UIManager:close(dialog)
        self:search(query, field)
    end
    dialog = InputDialog:new{
        title = field == "author" and _("Author") or _("Book title"), input = "",
        input_hint = _("Search for books to add to your library"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = submit },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Requests:search(query, field)
    self:fetch("GET", "/search?q=" .. encode(query) .. "&field=" .. field, nil, function(body)
        local rows = {{ text = _("Back"), callback = function() self:home() end }}
        if body.noProviders then
            table.insert(rows, { text = _("No metadata search providers are enabled. Check BookOrbit settings.") })
        elseif #(body.items or {}) == 0 then
            table.insert(rows, { text = _("No books found. Try a shorter title or search by author.") })
        end
        if body.partial or body.limited then
            table.insert(rows, { text = _("Results are incomplete. Refine your search or try again.") })
        end
        for _i, candidate in ipairs(body.items or {}) do
            local book = candidate
            local title = book.title .. "\n" .. table.concat(book.authors or {}, ", ")
            if book.language then title = title .. " [" .. book.language .. "]" end
            if book.availability and book.availability.ownedBookId then title = title .. " [" .. _("In library") .. "]" end
            table.insert(rows, { text = title, callback = function() self:select(book) end })
        end
        self:show(_("Search results"), rows)
    end)
end

function Requests:openBook(id)
    self:close()
    self.plugin:openBookDetails(id)
end

function Requests.requestPayload(book)
    local payload = {}
    for _i, key in ipairs({ "title", "authors", "isbn10", "isbn13", "providerKey", "providerId", "seriesName" }) do payload[key] = book[key] end
    if book.language and book.language ~= "en" and book.language ~= "eng" then payload.isbn10 = nil; payload.isbn13 = nil end
    payload.language = "en"
    payload.seriesIndex = tonumber(book.seriesIndex)
    return payload
end

function Requests:select(book)
    local availability = book.availability or {}
    if availability.ownedBookId then self:openBook(availability.ownedBookId); return end
    if availability.alreadySubscribed and availability.existingRequestId then
        self:detail(availability.existingRequestId); return
    end
    local explanation = self.automaticApproval and _("BookOrbit will try to acquire this book automatically.")
        or _("An administrator must approve this request before acquisition.")
    local details = book.title .. "\n" .. table.concat(book.authors or {}, ", ")
    details = details .. "\n" .. _("Requested language: English")
    if book.isbn13 then details = details .. "\nISBN: " .. book.isbn13 end
    UIManager:show(ConfirmBox:new{
        text = details .. "\n\n" .. explanation,
        ok_text = availability.existingRequestId and _("Join request") or _("Request book"),
        ok_callback = function()
            local payload = Requests.requestPayload(book)
            self:fetch("POST", "", payload, function(body) self:showDetail(body.request) end)
        end,
    })
end

function Requests:list(page, filter)
    filter = filter or "all"
    self:fetch("GET", "?page=" .. page .. "&filter=" .. filter, nil, function(body)
        local rows = {{ text = _("Back"), callback = function() self:home() end }}
        for _i, request in ipairs(body.items or {}) do
            local id = request.id
            table.insert(rows, { text = request.title .. "\n" .. Requests.statusText(request), callback = function() self:detail(id) end })
        end
        if #(body.items or {}) == 0 then table.insert(rows, { text = _("No requests yet.") }) end
        table.insert(rows, { text = _("Refresh"), callback = function() self:list(page, filter) end })
        if page > 1 then table.insert(rows, { text = _("Previous requests"), callback = function() self:list(page - 1, filter) end }) end
        if page * body.pageSize < body.total then
            table.insert(rows, { text = _("More requests"), callback = function() self:list(page + 1, filter) end })
        end
        self:show(_("My requests"), rows)
    end)
end

function Requests:detail(id, quiet)
    self:fetch("GET", "/" .. id, nil, function(body) self:showDetail(body, quiet) end, quiet)
end

function Requests:releases(request, page, refresh)
    self:fetch("GET", "/" .. request.id .. "/releases?page=" .. page .. "&refresh=" .. tostring(refresh == true), nil, function(body)
        local rows = {{ text = _("Back to request"), callback = function() self:detail(request.id) end }}
        if body.noSources then table.insert(rows, { text = _("No acquisition sources are enabled.") })
        elseif #(body.items or {}) == 0 then table.insert(rows, { text = _("No releases found.") }) end
        if body.partial then table.insert(rows, { text = _("Some sources could not be searched.") }) end
        for _i, item in ipairs(body.items or {}) do
            local release = item
            local details = table.concat({ release.format or "?", release.language or _("Unknown language"), release.source or "" }, " / ")
            if tonumber(release.sizeBytes) then details = details .. string.format(" / %.1f MB", release.sizeBytes / 1048576) end
            if release.triedBefore then details = details .. " / " .. _("Previously tried") end
            if release.vipOnly then details = details .. " / " .. _("VIP only") end
            table.insert(rows, { text = release.title .. "\n" .. details, callback = function()
                UIManager:show(ConfirmBox:new{
                    text = release.title .. "\n" .. details .. "\n\n" .. _("Download this release through BookOrbit?"),
                    ok_text = _("Download release"),
                    ok_callback = function()
                        self:fetch("POST", "/" .. request.id .. "/grab", { releaseId = release.releaseId }, function(body) self:showDetail(body) end)
                    end,
                })
            end })
        end
        table.insert(rows, { text = _("Refresh releases"), callback = function() self:releases(request, 1, true) end })
        if page > 1 then table.insert(rows, { text = _("Previous releases"), callback = function() self:releases(request, page - 1, false) end }) end
        if page * body.pageSize < body.total then table.insert(rows, { text = _("More releases"), callback = function() self:releases(request, page + 1, false) end }) end
        self:show(_("Choose a release"), rows)
    end)
end

function Requests:replace(request)
    local rows = {{ text = _("Back to request"), callback = function() self:showDetail(request) end }}
    for _i, entry in ipairs({ {"en", _("English")}, {"fr", _("French")}, {"es", _("Spanish")},
        {"de", _("German")}, {"it", _("Italian")}, {"pt", _("Portuguese")}, {"ca", _("Catalan")} }) do
        local code, label = entry[1], entry[2]
        table.insert(rows, { text = label, callback = function()
            UIManager:show(ConfirmBox:new{
                text = request.title .. "\n" .. _("Requested language: ") .. label .. "\n\n"
                    .. _("Request another edition? The current library and Kobo copies stay in place. When ready, choose Download replacement / Swap copy.")
                    .. "\n\n" .. _("Your usual approval permissions still apply."),
                ok_text = _("Request replacement"),
                ok_callback = function()
                    self:fetch("POST", "/" .. request.id .. "/replacement", { language = code }, function(body)
                        if body.request.canChooseRelease then self:releases(body.request, 1, false)
                        else self:showDetail(body.request) end
                    end)
                end,
            })
        end })
    end
    self:show(_("Replacement language"), rows)
end

function Requests:showDetail(request, quiet)
    local key = table.concat({tostring(request.id), request.status or "", tostring(math.floor(tonumber(request.progressPercent) or 0)), tostring(request.bookId), tostring(request.canCancel), tostring(request.canRetry), tostring(request.canChooseRelease), tostring(request.canDiscardHeld)}, "|")
    if quiet and self.detail_key == key then
        self.unchanged_polls = math.min((self.unchanged_polls or 0) + 1, 2)
        self:watchRequest(request)
        return
    end
    self.unchanged_polls = 0
    self:renderDetail(request)
    self.detail_key = key
end

function Requests:renderDetail(request)
    local rows = {
        { text = Requests.statusText(request) },
        { text = table.concat(request.authors or {}, ", ") },
        { text = _("Refresh status"), callback = function() self:detail(request.id) end },
        { text = _("My requests"), callback = function() self:list(1) end },
        { text = _("Find another book"), callback = function() self:home() end },
    }
    if request.language then table.insert(rows, 2, { text = _("Requested language: ") .. request.language }) end
    if request.languageNeedsReview then
        table.insert(rows, 1, { text = _("The downloaded file has the wrong language or no embedded language. It was held before import.") })
    end
    if request.canDiscardHeld then
        table.insert(rows, 1, { text = _("Discard held download / Try another"), callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Discard this unimported download and choose another release? Existing library and Kobo copies are kept."),
                ok_text = _("Discard held download"),
                ok_callback = function()
                    self:fetch("POST", "/" .. request.id .. "/discard-held", {}, function(body)
                        self:releases(body, 1, false)
                    end)
                end,
            })
        end })
    end
    if request.canCancel then table.insert(rows, {text = _("Cancel request"), callback = function()
        UIManager:show(ConfirmBox:new{text = _("Cancel this acquisition request?"), ok_text = _("Cancel request"), ok_callback = function()
            self:fetch("POST", "/" .. request.id .. "/cancel", {}, function(body) self:showDetail(body) end)
        end})
    end}) end
    if request.canRetry then table.insert(rows, {text = _("Retry automatic acquisition"), callback = function()
        self:fetch("POST", "/" .. request.id .. "/retry", {}, function(body) self:showDetail(body) end)
    end}) end
    if request.canReplace then
        table.insert(rows, 1, { text = _("Wrong language / Replace edition"), callback = function() self:replace(request) end })
    end
    if request.canChooseRelease then
        table.insert(rows, 1, { text = request.status == "failed" and _("Try another release") or _("Choose a release"),
            callback = function() self:releases(request, 1, false) end })
    end
    if request.status == "available" and request.bookId then
        table.insert(rows, 1, { text = _("Open in library / Download"), callback = function() self:openBook(request.bookId) end })
        if request.replacementBookId then
            table.insert(rows, 1, { text = _("Download replacement / Swap copy"), callback = function()
                self:close()
                self.plugin:openReplacement(request.bookId, request.replacementBookId)
            end })
        end
    end
    self:show(request.title, rows)
    if request.status == "available" and request.bookId then
        self.completed_requests = self.completed_requests or {}
        if not self.completed_requests[request.id] then
            self.completed_requests[request.id] = true
            self.plugin:onBookOrbitDownloadComplete()
        end
    end
    self:watchRequest(request)
end

function Requests:watchRequest(request)
    if self.watch_timer then UIManager:unschedule(self.watch_timer); self.watch_timer = nil end
    if request.retryQueued or request.status == "approved" or request.status == "searching" or request.status == "grabbed"
        or request.status == "downloading" or request.status == "importing" then
        local menu = self.menu
        self.watch_timer = function()
            self.watch_timer = nil
            if not self.closed and self.menu == menu and not self.busy then self:detail(request.id, true) end
        end
        UIManager:scheduleIn(10 * 2 ^ (self.unchanged_polls or 0), self.watch_timer)
    end
end

function Requests.open(plugin)
    local screen = setmetatable({ plugin = plugin, client = Api.new(plugin:apiOpts(true)) }, Requests)
    screen:fetch("GET", "/options", nil, function(body)
        screen.automaticApproval = body.automaticApproval
        screen:home()
    end)
    return screen
end

return Requests
