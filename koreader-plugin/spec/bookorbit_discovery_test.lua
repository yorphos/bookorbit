dofile("koreader-plugin/spec/bookorbit_requests_test.lua")
local client = require("bookorbit_api").new()
local calls, opened, bulk = {}, nil, nil
local book = {title = "A Christmas Carol", authors = {"Charles Dickens"}, providerKey = "openLibrary", providerId = "OL1W", availability = {}}
function client:request(method, path, payload)
    calls[#calls + 1] = {method = method, path = path, payload = payload}
    if path:find("/options", 1, true) then return {automaticApproval = false} end
    if path:find("/search?", 1, true) or path:find("/browse?", 1, true) then return {items = {book}, hasMore = true} end
    if path:find("?page=", 1, true) then return {items = {}, total = 0, pageSize = 20} end
    return {results = {}}
end
local plugin = {apiOpts = function() return {} end, openBookDetails = function(_, id) opened = id end,
    onBookOrbitDownloadComplete = function() end, openBookOrbit = function() end, browseCatalog = function() end,
    catalog_browser = {onDeviceBookPath = function(_, b) return b.id == 8 and "/books/carol.epub" or nil end,
        confirmBulkBooks = function(_, books, name, opts) bulk = {books = books, name = name, opts = opts} end}}
local ui = require("ui/uimanager")
ui.nextTick = function(_, fn) fn() end
local shown
ui.show = function(_, widget) shown = widget end
local Discovery = require("bookorbit_discovery")
local d = Discovery.open(plugin)
local function click(label)
    for _, row in ipairs(d.menu.item_table) do if row.text == label then row.callback(); return end end
    error("missing action " .. label)
end
assert(d.menu.title == "Discover and request books")
click("Search library and catalogs"); click("Search by isbn"); assert(shown.title == "Search by isbn")
d:results("Christmas Carol", "title", "search", 1)
assert(calls[#calls].path:find("/discovery/search?field=title", 1, true))
click("Next page"); assert(calls[#calls].path:find("page=2", 1, true))
d:book(book); click("More by Charles Dickens"); assert(calls[#calls].path:find("/browse?mode=author", 1, true))
d:inbox(); click("Ready to Read"); assert(calls[#calls].path:find("filter=ready", 1, true))
book.availability = {ownedBookId = 8}
assert(d:bookLabel(book):find("Downloaded on this Kobo", 1, true))
d:book(book); click("Download / Read"); assert(opened == 8)
d = Discovery.open(plugin)
local first = {title = "First", authors = {"Writer"}, seriesIndex = 1, availability = {ownedBookId = 9}}
local second = {title = "Second", authors = {"Writer"}, seriesIndex = 2, availability = {ownedBookId = 8}}
d:seriesPage("Test series", nil, {items = {first, second}, orderingComplete = true, next = second}, 1)
click("Download numbered volumes in reading order (2)")
assert(bulk.books[1].id == 9 and bulk.books[2].id == 8 and bulk.opts.preserve_order)
d = Discovery.open(plugin)
d:seriesPage("Unknown", nil, {items = {book}, orderingComplete = false}, 1)
for _, row in ipairs(d.menu.item_table) do assert(not row.text:find("Continue series:", 1, true)) end
print("Discovery: native search, pagination, author browse, inbox, local status, ordered bulk and unknown ordering passed")
