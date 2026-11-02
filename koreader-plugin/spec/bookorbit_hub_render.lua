-- Run with the official Linux KOReader runtime's luajit, from its runtime
-- directory. These are native widgets and fonts, not an HTML approximation.
-- BOOKORBIT_PLUGIN_DIR points to bookorbit.koplugin; BOOKORBIT_PREVIEW_DIR
-- holds optional Gutenberg cover-{98,11,84,1661}.jpg and receives the PNGs.
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
for name, s in pairs(screens) do
    if name == "search" or name == "books" or name == "discover" then
        local time_machine = {title="The Time Machine", authors={"H. G. Wells"}, language="en", formats={"EPUB"}}
        local rows = require("bookorbit_hub_theme").geometry(1072,1448).rows
        s.visible = {tale, alice, frank, sherlock, time_machine}
        while #s.visible > rows do table.remove(s.visible) end
    end
    local page = Page:new{build = function(_, w, h) return View.build(s, w, h) end}
    page:paintTo(framebuffer, 0, 0)
    framebuffer:writePNG(dir .. "/" .. name .. ".png")
    local count = 0
    for _, hit in ipairs(page.hits) do
        if hit.action and hit.action.kind == "tab" and hit.dimen.y > 1200 then
            assert(hit.dimen.x >= 0 and hit.dimen.x + hit.dimen.w <= 1072)
            assert(hit.dimen.h >= 70, "Navigation target too small")
            count = count + 1
        end
    end
    assert(count == 4, "Four persistent navigation targets required")
    if View.isList(s.route.kind) then assert(s.measuredBodyHeight <= s.bodyBounds.h, name .. " list overflows") end
    print(name, "body", s.measuredBodyHeight, "viewport", s.bodyBounds.h, "hits", #page.hits)
    page:free()
end
assert(Model.status({localPath = "/x", bookId = 1}) == "Downloaded")
print("Native Clara BW screen renders passed")
