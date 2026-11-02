-- Presentation only: acquisition, permissions and source credentials stay on BookOrbit.
local M = {}

function M.encode(value)
    return (
        tostring(value or ""):gsub("([^%w%-_%.~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    )
end

function M.book(value, request)
    local book = {}
    for key, item in pairs(value or {}) do
        book[key] = item
    end
    book.authors = book.authors or {}
    local availability = book.availability or {}
    book.bookId = book.bookId or availability.ownedBookId or (not request and book.detailUrl and book.id)
    book.requestId = request and book.id or availability.existingRequestId
    book.requestStatus = request and book.status or availability.existingRequestStatus
    book.request = request and value or nil
    return book
end

local statuses = {
    pending = "Awaiting approval",
    approved = "Requested",
    searching = "Searching",
    grabbed = "Download queued",
    downloading = "Downloading",
    importing = "Importing",
    available = "Ready to read",
    failed = "Failed",
    needs_review = "Needs review",
    rejected = "Rejected",
    cancelled = "Cancelled",
}

function M.status(book)
    if book.localPath then
        return "Downloaded"
    end
    if book.bookId then
        return "In library"
    end
    if book.requestStatus then
        return statuses[book.requestStatus] or book.requestStatus
    end
    return book.unavailable and "Unavailable" or "Requestable"
end

function M.stage(request)
    return statuses[request and request.status] or "Status unavailable"
end

-- Progress steps shown on a request page, and the step each status reaches.
M.STEPS = { "Requested", "Searching", "Downloading", "Importing", "Ready" }
local step_of = {
    pending = 1,
    approved = 2,
    searching = 2,
    grabbed = 3,
    downloading = 3,
    importing = 4,
    needs_review = 4,
    available = 5,
}

-- Returns the reached step (1..5) and whether it is waiting on a person
-- (approval or review). Failed, rejected and cancelled requests have no step:
-- the server does not say where they stopped.
function M.step(request)
    local status = request and request.status
    if not step_of[status] then
        return nil
    end
    return step_of[status], status == "pending" or status == "needs_review"
end

-- Statuses where the server is still working on the request.
local active = { approved = true, searching = true, grabbed = true, downloading = true, importing = true }
function M.isActive(status)
    return active[status] == true
end

-- Statuses that no longer change without someone acting on them.
local settled = { available = true, failed = true, rejected = true, cancelled = true }
function M.isSettled(status)
    return settled[status] == true
end

-- Only catalog metadata is sent for a request; never a source URL.
function M.requestPayload(book)
    local payload = {}
    for _, key in ipairs({ "title", "authors", "isbn10", "isbn13", "providerKey", "providerId", "seriesName" }) do
        payload[key] = book[key]
    end
    if book.language and book.language ~= "en" and book.language ~= "eng" then
        payload.isbn10 = nil
        payload.isbn13 = nil
    end
    payload.language = "en"
    payload.seriesIndex = tonumber(book.seriesIndex)
    return payload
end

-- The server's own reason for a refused action, cut to one readable line.
function M.serverMessage(errbody)
    local message = type(errbody) == "table" and errbody.message
    if type(message) == "table" then
        message = message[1]
    end
    if type(message) ~= "string" then
        return nil
    end
    message = message:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if message == "" then
        return nil
    end
    if #message > 160 then
        message = message:sub(1, 157):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…"
    end
    return message
end

-- What to tell the reader when a request to BookOrbit fails.
function M.errorText(method, completed, err, errbody)
    if completed == false then
        return "Cancelled. Refresh to see whether BookOrbit received it."
    end
    local code = tonumber(err)
    local reason = M.serverMessage(errbody)
    if code == 401 then
        return "Your sign-in expired. Reconnect your account in Settings."
    end
    if code == 403 then
        return reason and ("Not allowed: " .. reason) or "Your account isn't allowed to do this. Ask the library admin."
    end
    if code == 404 then
        return reason and (reason .. " · Refresh and try again.")
            or "This item no longer exists. Refresh and try again."
    end
    if code == 429 then
        return "Too many requests. Wait a minute, then try again."
    end
    if code and code >= 400 and code < 500 then
        return reason or "BookOrbit refused this action. Refresh and try again."
    end
    if code and code >= 500 then
        return reason and (reason .. " · Try again shortly.") or "BookOrbit had a server error. Try again shortly."
    end
    if method ~= "GET" then
        return "No reply from BookOrbit. Refresh Requests before trying again, so nothing is sent twice."
    end
    return "Can't reach BookOrbit. Refresh to retry, or read downloaded books offline."
end

function M.meta(book)
    local parts = {}
    if book.seriesName then
        parts[#parts + 1] = book.seriesName .. (book.seriesIndex ~= nil and (" #" .. tostring(book.seriesIndex)) or "")
    end
    if book.language then
        parts[#parts + 1] = M.language(book.language)
    end
    if book.formats and #book.formats > 0 then
        parts[#parts + 1] = table.concat(book.formats, ", ")
    end
    return table.concat(parts, "  ·  ")
end

function M.language(value)
    local names = {
        en = "English",
        eng = "English",
        ca = "Catalan",
        cat = "Catalan",
        es = "Spanish",
        spa = "Spanish",
        fr = "French",
        fra = "French",
        fre = "French",
        de = "German",
        deu = "German",
        ger = "German",
        it = "Italian",
        ita = "Italian",
        pt = "Portuguese",
        por = "Portuguese",
        nl = "Dutch",
        nld = "Dutch",
        dut = "Dutch",
        ru = "Russian",
        rus = "Russian",
        pl = "Polish",
        pol = "Polish",
        ja = "Japanese",
        jpn = "Japanese",
        zh = "Chinese",
        zho = "Chinese",
        und = "Unknown language",
    }
    return value and (names[value:lower()] or value) or "Unknown language"
end

function M.percent(value)
    value = tonumber(value)
    if not value or value ~= value then
        return nil
    end
    return math.max(0, math.min(100, value))
end

function M.plain(value)
    return tostring(value or ""):gsub("<[^>]*>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("%s+", " ")
end

function M.bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 ^ 3 then
        return string.format("%.1f GB", bytes / 1024 ^ 3)
    end
    return string.format("%.1f MB", bytes / 1024 ^ 2)
end

-- Only metadata is persisted or sent for a request. Never pass a source URL.
function M.wishlist(book)
    local item = { title = book.title, authors = book.authors }
    for _, key in ipairs({ "isbn10", "isbn13", "language", "providerKey", "providerId", "seriesName" }) do
        item[key] = book[key]
    end
    item.seriesIndex = tonumber(book.seriesIndex)
    if type(book.coverUrl) == "string" and book.coverUrl:match("^https://") then
        item.coverUrl = book.coverUrl
    end
    return item
end

function M.slice(items, page, size)
    local result = {}
    for index = (page - 1) * size + 1, math.min(#items, page * size) do
        result[#result + 1] = items[index]
    end
    return result
end

function M.seriesActions(body)
    local missing, owned = {}, {}
    for _, book in ipairs(body.items or {}) do
        local id = book.bookId or (book.availability and book.availability.ownedBookId)
        if tonumber(book.seriesIndex) ~= nil then
            if id then
                owned[#owned + 1] = { id = id, title = book.title, seriesIndex = book.seriesIndex }
            elseif not (book.availability and book.availability.existingRequestId) then
                missing[#missing + 1] = book
            end
        end
    end
    local function ordered(a, b)
        return tonumber(a.seriesIndex) < tonumber(b.seriesIndex)
    end
    table.sort(missing, ordered)
    table.sort(owned, ordered)
    return {
        missing = missing,
        owned = owned,
        complete = not body.partial and not body.truncated,
        continue = body.orderingComplete and not body.partial and not body.truncated and body.next or nil,
    }
end

return M
