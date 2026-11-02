-- Presentation only: acquisition, permissions and source credentials stay on BookOrbit.
local M = {}

function M.encode(value)
    return (tostring(value or ""):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function M.book(value, request)
    local book = {}
    for key, item in pairs(value or {}) do book[key] = item end
    book.authors = book.authors or {}
    local availability = book.availability or {}
    book.bookId = book.bookId or availability.ownedBookId or (not request and book.detailUrl and book.id)
    book.requestId = request and book.id or availability.existingRequestId
    book.requestStatus = request and book.status or availability.existingRequestStatus
    book.request = request and value or nil
    return book
end

local statuses = {
    pending = "Awaiting approval", approved = "Requested", searching = "Searching",
    grabbed = "Download queued", downloading = "Downloading", importing = "Importing",
    available = "Ready to read", failed = "Failed", needs_review = "Needs review",
    rejected = "Rejected", cancelled = "Cancelled",
}

function M.status(book)
    if book.localPath then return "Downloaded" end
    if book.bookId then return "In library" end
    if book.requestStatus then return statuses[book.requestStatus] or book.requestStatus end
    return book.unavailable and "Unavailable" or "Requestable"
end

function M.stage(request)
    return statuses[request and request.status] or "Status unavailable"
end

function M.meta(book)
    local parts = {}
    if book.seriesName then parts[#parts + 1] = book.seriesName .. (book.seriesIndex ~= nil and (" #" .. tostring(book.seriesIndex)) or "") end
    if book.language then parts[#parts + 1] = M.language(book.language) end
    if book.formats and #book.formats > 0 then parts[#parts + 1] = table.concat(book.formats, ", ") end
    return table.concat(parts, "  ·  ")
end

function M.language(value)
    local names = {en="English", eng="English", ca="Catalan", cat="Catalan", es="Spanish", spa="Spanish", fr="French", fra="French", fre="French", de="German", deu="German", ger="German", it="Italian", ita="Italian", pt="Portuguese", por="Portuguese", nl="Dutch", nld="Dutch", dut="Dutch", ru="Russian", rus="Russian", pl="Polish", pol="Polish", ja="Japanese", jpn="Japanese", zh="Chinese", zho="Chinese", und="Unknown language"}
    return value and (names[value:lower()] or value) or "Unknown language"
end

function M.percent(value)
    value = tonumber(value)
    if not value or value ~= value then return nil end
    return math.max(0, math.min(100, value))
end

function M.plain(value)
    return tostring(value or ""):gsub("<[^>]*>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("%s+", " ")
end

function M.bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024^3 then return string.format("%.1f GB", bytes / 1024^3) end
    return string.format("%.1f MB", bytes / 1024^2)
end

-- Only metadata is persisted or sent for a request. Never pass a source URL.
function M.wishlist(book)
    local item = { title = book.title, authors = book.authors }
    for _, key in ipairs({"isbn10", "isbn13", "language", "providerKey", "providerId", "seriesName"}) do item[key] = book[key] end
    item.seriesIndex = tonumber(book.seriesIndex)
    if type(book.coverUrl) == "string" and book.coverUrl:match("^https://") then item.coverUrl = book.coverUrl end
    return item
end

function M.slice(items, page, size)
    local result = {}
    for index = (page - 1) * size + 1, math.min(#items, page * size) do result[#result + 1] = items[index] end
    return result
end

function M.seriesActions(body)
    local missing, owned = {}, {}
    for _, book in ipairs(body.items or {}) do
        local id = book.bookId or (book.availability and book.availability.ownedBookId)
        if tonumber(book.seriesIndex) ~= nil then
            if id then owned[#owned + 1] = {id = id, title = book.title, seriesIndex = book.seriesIndex}
            elseif not (book.availability and book.availability.existingRequestId) then missing[#missing + 1] = book end
        end
    end
    local function ordered(a, b) return tonumber(a.seriesIndex) < tonumber(b.seriesIndex) end
    table.sort(missing, ordered); table.sort(owned, ordered)
    return { missing = missing, owned = owned, complete = not body.partial and not body.truncated,
        continue = body.orderingComplete and not body.partial and not body.truncated and body.next or nil }
end

return M
