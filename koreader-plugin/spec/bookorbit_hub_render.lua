-- Run with the official Linux KOReader runtime's luajit, from its runtime
-- directory. These are native widgets and fonts, not an HTML approximation.
-- BOOKORBIT_PLUGIN_DIR points to bookorbit.koplugin; BOOKORBIT_PREVIEW_DIR
-- holds optional Gutenberg cover-{98,11,84,1661}.jpg and receives the PNGs.
-- BOOKORBIT_GOLDEN_DIR: compare each screen with its saved outline there and
-- fail when the layout moved; BOOKORBIT_GOLDEN_UPDATE=1 saves new outlines.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/settings.reader.lua")
G_reader_settings:saveSetting("sdl_window", {width = 1072, height = 1448})
package.path = os.getenv("BOOKORBIT_PLUGIN_DIR") .. "/?.lua;" .. package.path
local Device = require("device")
Device.screen:setDPI(300)
Device.screen.dpi_override = nil -- Physical 300 PPI, without a user DPI override.
require("document/canvascontext"):init(Device)
local Metrics = require("bookorbit_board_metrics")
Metrics.setUserScale(tonumber(os.getenv("BOOKORBIT_UI_SCALE")) or 1.05)
local View = require("bookorbit_hub_view")
local Page = require("bookorbit_menu_page")
local Model = require("bookorbit_hub_model")
local BB = require("ffi/blitbuffer")
local framebuffer = BB.new(1072, 1448, BB.TYPE_BB8)
local dir = os.getenv("BOOKORBIT_PREVIEW_DIR")
local golden_dir, golden_update = os.getenv("BOOKORBIT_GOLDEN_DIR"), os.getenv("BOOKORBIT_GOLDEN_UPDATE") == "1"
local scale_name = tostring(tonumber(os.getenv("BOOKORBIT_UI_SCALE")) or 1.05)
-- The screen at 1/16 size: one average grey per 16 x 16 block. Coarse enough to
-- ignore anti-aliasing, fine enough to catch a moved, missing or clipped block.
local BLOCK = 16
local function outline(bb)
    local rows = {}
    for by = 0, math.floor(bb:getHeight() / BLOCK) - 1 do
        local cells = {}
        for bx = 0, math.floor(bb:getWidth() / BLOCK) - 1 do
            local sum = 0
            for y = by * BLOCK, by * BLOCK + BLOCK - 1, 2 do
                for x = bx * BLOCK, bx * BLOCK + BLOCK - 1, 2 do
                    sum = sum + bb:getPixel(x, y):getColor8().a
                end
            end
            cells[#cells + 1] = string.format("%02x", math.floor(sum / (BLOCK * BLOCK / 4)))
        end
        rows[#rows + 1] = table.concat(cells)
    end
    return rows
end
local function checkGolden(name, bb)
    if not golden_dir then return end
    local path = golden_dir .. "/" .. name .. "@" .. scale_name .. ".txt"
    local now = outline(bb)
    local f = io.open(path, "r")
    if golden_update or not f then
        if f then f:close() end
        assert(golden_update, "No saved outline for " .. name .. "; run with BOOKORBIT_GOLDEN_UPDATE=1")
        local out = assert(io.open(path, "w")); out:write(table.concat(now, "\n"), "\n"); out:close()
        return
    end
    local saved = {}
    for line in f:lines() do saved[#saved + 1] = line end
    f:close()
    local differing, total, x0, y0, x1, y1 = 0, 0
    for row, line in ipairs(now) do
        local old = saved[row] or ""
        for col = 1, #line / 2 do
            total = total + 1
            local a = tonumber(line:sub(col * 2 - 1, col * 2), 16)
            local b = tonumber(old:sub(col * 2 - 1, col * 2), 16) or -255
            if math.abs(a - b) > 24 then
                differing = differing + 1
                x0, y0 = math.min(x0 or col, col), math.min(y0 or row, row)
                x1, y1 = math.max(x1 or col, col), math.max(y1 or row, row)
            end
        end
    end
    if differing <= total * 0.01 then return end
    error(string.format("%s moved: %d of %d blocks differ, around x %d-%d, y %d-%d px. Check %s.png; if intended, run with BOOKORBIT_GOLDEN_UPDATE=1",
        name, differing, total, (x0 - 1) * BLOCK, x1 * BLOCK, (y0 - 1) * BLOCK, y1 * BLOCK, name), 0)
end
local function book(title, author, cover, extra)
    local b = {title = title, authors = {author}, coverPath = dir .. "/cover-" .. cover .. ".jpg", language = "en", formats = {"EPUB"}}
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end
local tale = book("A Tale of Two Cities", "Charles Dickens", 98, {bookId = 30})
local alice = book("Alice's Adventures in Wonderland", "Lewis Carroll", 11, {localPath = "/books/Alice.epub", progressPercentage = 42})
local frank = book("Frankenstein", "Mary Shelley", 84)
local sherlock = book("The Adventures of Sherlock Holmes", "Arthur Conan Doyle", 1661, {seriesName = "Sherlock Holmes", seriesIndex = 3})
local requested = book("Frankenstein", "Mary Shelley", 84, {request = {id = 1, status = "downloading", progressPercent = 25}, requestId = 1, requestStatus = "downloading"})
local function state(kind, tab, body)
    return {route = {kind = kind, page = 1}, tab = tab or kind, body = body or {}, visible = {tale, alice, frank}, title = kind,
        recommendations = {tale, alice, frank, sherlock}, continueReading = {alice}, requests = {requested}, pageLabel = "Page 1 of 4", next = true}
end
local screens = {}
screens.settings = state("settings", "home"); screens.settings.version = "2.5.0"
screens.settings.updateVersion = "2.4.1"
screens.home = state("home", "home", {recommendationReason = "From your library"})
screens.discover = state("discover", "discover"); screens.discover.title = "For You"; screens.discover.subtitle = "Based on your last 3 books"
screens.search = state("search", "discover"); screens.search.title = "Universal Search"; screens.search.route.q = "classic fiction"; screens.search.route.scope = "all"
screens.detail = state("detail", "discover"); screens.detail.book = book("Frankenstein", "Mary Shelley", 84, {description = "A young scientist brings a living creature into the world, then abandons it. Mary Shelley's novel follows the consequences of his ambition and the creature's search for companionship.", genres = {"Gothic fiction"}})
screens.requests = state("requests", "requests"); screens.requests.title = "Requests Queue"; screens.requests.visible = {requested, book("A Tale of Two Cities", "Charles Dickens", 98, {bookId = 30, request = {id = 2, status = "available"}}), book("Alice's Adventures in Wonderland", "Lewis Carroll", 11, {request = {id = 3, status = "failed"}})}
screens.books = state("books", "books"); screens.books.title = "My Books"; screens.books.route.filter = "local"; screens.books.subtitle = "3 downloaded · 9.2 MB used · Available offline"
screens.series = state("series", "books", {items = {sherlock, tale}, orderingComplete = false}); screens.series.route.q = "Sherlock Holmes"; screens.series.visible = {sherlock, book("The Memoirs of Sherlock Holmes", "Arthur Conan Doyle", 1661, {seriesName = "Sherlock Holmes", seriesIndex = 4}), book("The Hound of the Baskervilles", "Arthur Conan Doyle", 1661, {seriesName = "Sherlock Holmes", seriesIndex = 5, requestStatus = "pending"})}
screens.request_detail = state("request_detail", "requests", {id = 1, title = "Frankenstein", authors = {"Mary Shelley"}, status = "failed", canRetry = true, canChooseRelease = true, canCancel = true}); screens.request_detail.book = book("Frankenstein", "Mary Shelley", 84, {request = {id = 1, status = "failed"}, requestStatus = "failed"})
screens.request_downloading = state("request_detail", "requests", {id = 2, title = "Walden", authors = {"Henry David Thoreau"}, status = "downloading", progressPercent = 40, canCancel = true}); screens.request_downloading.book = book("Walden", "Henry David Thoreau", 40, {request = {id = 2, status = "downloading", progressPercent = 40}, requestStatus = "downloading"})
for _, b in ipairs(screens.series.visible) do b.displayTitle = "#" .. tostring(b.seriesIndex) .. " · " .. b.title end
screens.roulette=state("roulette","discover",{onboarded=true})
screens.roulette.book=book("Frankenstein; or, The Modern Prometheus","Mary Shelley",84,{genres={"Gothic","Horror"},description="A scientist creates life and abandons his lonely creature. Mary Shelley's novel follows the consequences of ambition and the creature's search for companionship.",recommendationWhy="Shares Gothic and Horror with a book you liked."})
screens.matches=state("matches","discover");screens.matches.title="Matches";screens.matches.visible={frank,sherlock,tale};screens.matches.selectedCount=2
screens.home.canResume=true
screens.home.homeStats = "3-day reading streak · 5 of 24 books in 2026"
screens.home.ready = {tale, sherlock}
screens.stats = state("stats", "books", {goal={goal=24,done=5,year=2026}, streak={current=3,longest=9}, minutes={today=20,week=140,month=600,year=5000}, lastFourteenDays={0,10,20,30,0,40,50,60,0,70,80,90,0,20}, readingDaysThisYear=120, finishedTotal=40, readingNow=2})
screens.stats.finished = {tale, alice, frank}
screens.social = state("social", "discover", {share = true, people = {"Bea", "Sam"}})
screens.social.title = "Friends"
screens.social.visible = {book("A Tale of Two Cities", "Charles Dickens", 98, {bookId = 30, hint = "Bea recommends: Loved it"}), book("Frankenstein", "Mary Shelley", 84, {bookId = 31, hint = "Sam finished"})}
screens.social_off = state("social", "discover", {share = false})
screens.social_off.title = "Friends"; screens.social_off.visible = {}
screens.hub_settings = state("hub_settings", "home"); screens.hub_settings.settings = {}
screens.diagnostics = state("diagnostics", "home")
screens.diagnostics.diag = {version = "2.2.0+yrp.2", user = "reader", connected = true, cache = {files = 12, bytes = 81920, dirty = 1, memory = 5}, covers = 140, coverBytes = 4200000,
    outbox = {"Wishlist: Walden · 3 min ago"}, watched = {"Frankenstein · Downloading · changed 2 min ago"}, timings = {"Background process: 12 requests, average 0.41 s, last 0.30 s"},
    events = {"just now · Sent: match: Frankenstein", "1 h ago · Error: GET /koreader/plugin/hub/home: network_error"}, upkeep = "2 h ago · Downloaded 1 book"}
local names = {}
for name in pairs(screens) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    local s = screens[name]
    if name == "search" or name == "books" or name == "discover" then
        local time_machine = {title="The Time Machine", authors={"H. G. Wells"}, language="en", formats={"EPUB"}}
        local rows = require("bookorbit_hub_theme").geometry(1072,1448).rows
        s.visible = {tale, alice, frank, sherlock, time_machine}
        while #s.visible > rows do table.remove(s.visible) end
    end
    local page = Page:new{build = function(_, w, h) return View.build(s, w, h) end}
    page:paintTo(framebuffer, 0, 0)
    framebuffer:writePNG(dir .. "/" .. name .. ".png")
    checkGolden(name, framebuffer)
    local count = 0
    for _, hit in ipairs(page.hits) do
        -- Footer tabs are a quarter of the screen wide; "See all" links also open tabs.
        if hit.action and hit.action.kind == "tab" and hit.dimen and hit.dimen.w == math.floor(1072 / 4) and hit.dimen.y >= s.bodyBounds.y + s.bodyBounds.h then
            assert(hit.dimen.x >= 0 and hit.dimen.x + hit.dimen.w <= 1072)
            assert(hit.dimen.h >= 70, "Navigation target too small")
            count = count + 1
        end
    end
    assert(count == 4, "Four persistent navigation targets required")
    assert(s.measuredBodyHeight <= s.bodyBounds.h and s.scrolling == nil, name .. " does not fit the screen")
    print(name, "body", s.measuredBodyHeight, "viewport", s.bodyBounds.h, "hits", #page.hits)
    page:free()
end
assert(Model.status({localPath = "/x", bookId = 1}) == "Downloaded")
print("Native Clara BW screen renders passed")
