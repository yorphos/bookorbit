-- Native KOReader widgets/controller integration. Transport alone uses fixtures.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/hub-test.reader.lua")
G_reader_settings:saveSetting("sdl_window", {width = 1072, height = 1448})
package.path = os.getenv("BOOKORBIT_PLUGIN_DIR") .. "/?.lua;" .. package.path
local Device = require("device")
Device.screen:setDPI(300); Device.screen.dpi_override = nil
require("document/canvascontext"):init(Device)
require("bookorbit_board_metrics").setUserScale(tonumber(os.getenv("BOOKORBIT_UI_SCALE")) or 1.05)
local NetworkMgr = require("ui/network/manager")
local connected, connection_prompts = true, 0
NetworkMgr.isConnected = function() return connected end
NetworkMgr.runWhenConnected = function(_, fn) if connected then fn() else connection_prompts = connection_prompts + 1 end end
local records, status, requests, request_list = {}, "approved", {}, {}
for i = 1, 20 do records[i] = {bookId = i + 100, title = "Public-domain title " .. i, authors = {"An author"}, hasCover = false} end
local client = {}
function client:runInSubprocess(fn) local body, err, errbody = fn(); return true, {body = body, err = err, errbody = errbody} end
local etags = {}
function client:requestBlocking(method, path, payload, headers, meta)
    requests[#requests + 1] = {method = method, path = path, payload = payload, headers = headers}
    if etags[path] and meta then meta.etag = etags[path] end
    if etags[path] and headers and headers["if-none-match"] == etags[path] then return nil, 304, {} end
    if path:match("/refused$") then return nil, 403, {statusCode = 403, message = "Your account does not have permission to request books"}
    elseif path:match("roulette/decision$") then return {eventId=payload.eventId}
    elseif path:match("roulette/undo$") then return {undone=true}
    elseif path:match("roulette/acquire$") then return {results={{key=payload.keys[1],request={id=77,status="pending"}}}}
    elseif path:find("roulette/matches",1,true) then return {items={{title="Frankenstein",authors={"Mary Shelley"},matchKey=string.rep("a",32),providerKey="openLibrary",providerId="OL123W",genres={"Gothic","Horror"},description="A public-domain novel."}},hasMore=false}
    elseif path:find("hub/stats", 1, true) then return {goal={goal=24,done=5,year=2026},streak={current=3,longest=9},minutes={today=20,week=140,month=600,year=5000},lastFourteenDays={0,10,20,30,0,40,50,60,0,70,80,90,0,20},readingDaysThisYear=120,finishedTotal=40,readingNow=2,recentlyFinished=records}
    elseif path:find("hub/social/sharing", 1, true) then return {share=payload.share}
    elseif path:find("hub/social", 1, true) then return {share=true, people={"Bea"}, items={{id=5,title="Shared title",authors={"An author"},friend="Bea",kind="recommended",note="Loved it",detailUrl="/x"}}}
    elseif path:find("hub/wishlist", 1, true) then return {key=string.rep("c",32)}
    elseif path:find("roulette?count=", 1, true) then return {items={{rouletteKey=string.rep("b",32),title="Frankenstein; or, The Modern Prometheus",authors={"Mary Wollstonecraft Shelley"},genres={"Gothic","Horror","Science fiction"},description=string.rep("A scientist creates life and faces the consequences. ",12),recommendationWhy="Shares Gothic and Horror with a book you liked.",providerKey="openLibrary",providerId="OL123W"}},onboarded=false}
    elseif path:find("hub/home", 1, true) or path:find("hub/discover", 1, true) then return {recommendations = records, continueReading = {}, requests = {}, canRequest = true}
    elseif method == "POST" and (path:match("requests/77/replacement$") or path:match("requests/book/101/replacement$")) then return {request={id=78, title="Frankenstein", canChooseRelease=true, status="approved"}}
    elseif path:match("requests/91$") then return {id = 91, title = "Walden", authors = {"Henry David Thoreau"}, status = "downloading", progressPercent = 10}
    elseif path:match("requests/77$") then return {id = 77, title = "Frankenstein", authors = {"Mary Shelley"}, status = status, canChooseRelease=true, canRetry=true, canCancel=true, canDiscardHeld=true, canReplace=true, bookId = status == "available" and 101 or nil}
    elseif method == "POST" and path:match("requests$") then return {request = {id = 77, title = "Frankenstein", authors = {"Mary Shelley"}, status = status}}
    elseif path:find("catalog/books/", 1, true) then return {id = 101, bookId = 101, title = "Public-domain title", authors = {"An author"}, hasCover = false}
    elseif path:find("discovery/works", 1, true) then return {title = "Frankenstein", description = "A public-domain novel.", editions = {}}
    elseif path:find("requests/watch?ids=", 1, true) then
        local wanted, items = {}, {}
        for id in path:match("ids=([%d,]+)"):gmatch("%d+") do wanted[id] = true end
        for _, r in ipairs(request_list) do if wanted[tostring(r.id)] then items[#items + 1] = r end end
        return {items = items}
    elseif path:find("requests?", 1, true) then return {items = request_list, hasMore = false}
    else return {items = records, hasMore = false} end
end
require("bookorbit_api").new = function() return client end
local State = require("bookorbit_state_manager")
local offline_file = os.getenv("KO_HOME") .. "/offline-test.epub"
local file = assert(io.open(offline_file, "w")); file:write("Offline test fixture"); file:close()
State.hasOnDeviceMaps = function() return true end
State.onDeviceMaps = function() return {byBookId = {[50] = offline_file}, byFileId = {[500] = offline_file}, generation = 1} end
local Catalog = require("bookorbit_catalog")
Catalog.scheduleThumbnailDownloads = function() end
local Hub = require("bookorbit_hub")
local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local framebuffer = BB.new(1072, 1448, BB.TYPE_BB8)
local completions = 0
local plugin = {path = os.getenv("BOOKORBIT_PLUGIN_DIR"), settings = {server_url = "https://fixture.invalid", username = "native-test", userkey = "fixture", download_dir = os.getenv("KO_HOME")}}
function plugin:apiOpts() return self.settings end
function plugin:onBookOrbitDownloadComplete() completions = completions + 1 end
local updated
function plugin:hasKnownUpdate() return self.settings.update_latest_version ~= nil end
function plugin:applyUpdate(version) updated = version end
local hub = Hub.open(plugin, false, {kind = "home"})
local function paint() hub.page:paintTo(framebuffer, 0, 0) end
local function tap(kind, value)
    paint()
    for _, hit in ipairs(hub.page.hits) do
        if hit.action and hit.action.kind == kind and (not value or hit.action.tab == value) and hit.dimen then
            local d = hit.dimen
            hub.page:onTapPage(nil, {pos = Geom:new{x = d.x + d.w / 2, y = d.y + d.h / 2, w = 1, h = 1}})
            return
        end
    end
    error("No visible native target: " .. kind .. " " .. tostring(value))
end
assert(hub.state.body.canRequest == true, "Home must load real adapter data")
-- Repeated taps during an in-flight request must not schedule another GET or a mutation.
local original_run = client.runInSubprocess
local request_count = #requests
client.runInSubprocess = function(self, fn)
    self.runInSubprocess = original_run
    hub:load()
    hub:fetch("POST", "/should-not-run", {}, function() error("Repeated action executed") end)
    return original_run(self, fn)
end
hub:load()
assert(#requests == request_count + 1 and not hub.pendingFetch, "Coalesce refresh taps and reject queued mutations")
-- Navigation still works during a request, and only the latest destination is fetched.
request_count = #requests
client.runInSubprocess = function(self, fn)
    self.runInSubprocess = original_run
    hub:navigate({kind="search",q="superseded"})
    hub:navigate({kind="books"})
    return original_run(self, fn)
end
hub:load()
assert(#requests == request_count + 2 and hub.route.kind == "books" and not hub.state.loading, "Latest navigation wins without replaying intermediate searches")
hub:navigate({kind="home"})
local rebuilds, original_refresh = 0, hub.page.refresh
hub.page.refresh = function(...) rebuilds=rebuilds+1; return original_refresh(...) end
hub:navigate({kind="search",q="render check"})
assert(rebuilds == 2, "Navigation needs only loading and completed layouts, not an extra empty rebuild")
hub.page.refresh = original_refresh
hub:navigate({kind="home"})
plugin.settings.update_latest_version = "2.4.1"; hub:refreshView(); tap("update")
assert(updated == "2.4.1", "Header update must invoke the existing updater")
plugin.settings.update_latest_version = nil; hub:refreshView()
tap("tab", "discover"); assert(hub.route.kind == "discover")
assert(hub.state.scrolling == nil, "Book lists must never scroll")
assert(hub.state.measuredBodyHeight <= hub.state.bodyBounds.h, "Book list and pagination must fit the screen")
assert(hub.state.pageLabel:find("Page 1", 1, true))
hub:turnPage(1); assert(hub.state.pageLabel:find("Page 2", 1, true))
hub:action({kind="settings"}); assert(hub.route.kind == "settings")
hub:navigate({kind="request_detail", id=77, request={id=77, status="approved"}})
paint()
local manager = require("ui/uimanager")
manager:_repaint()
local paints, original_paint = 0, hub.page.paintTo
hub.page.paintTo = function(...) paints = paints + 1; return original_paint(...) end
local bounds = hub.state.bodyBounds
hub.page:handleEvent(require("ui/event"):new("Gesture", {ges = "swipe", direction = "north", distance = 400,
    pos = Geom:new{x = bounds.x + bounds.w / 2, y = bounds.y + bounds.h / 2, w = 1, h = 1}}))
assert(manager._dirty[hub.page], "Scrolling must mark the visible page dirty, not just advance its offset")
manager:_repaint()
assert(paints > 0, "The actual KOReader repaint loop must redraw scrolled content")
local scroll_y = hub.state.scrolling:getScrolledOffset().y
assert(scroll_y > 0, "Native vertical swipe must reach overflowing content")
hub:openBook(records[1]); hub:back()
assert(hub.state.scrolling:getScrolledOffset().y == scroll_y, "Back must preserve native scroll position")
hub:navigate({kind = "search", q = "classics", scope = "all", page = 1})
assert(hub.state.scrolling == nil and hub.state.measuredBodyHeight <= hub.state.bodyBounds.h, "Search must fit without scrolling")
hub.state.cached = true; hub.state.body.partial = true; hub:refreshView()
assert(hub.state.measuredBodyHeight <= hub.state.bodyBounds.h, "Notices and pagination must also fit")
assert(#hub.state.visible >= (tonumber(os.getenv("BOOKORBIT_UI_SCALE")) == 1.2 and 3 or 5), "Show more compact results per page")
local calls = #requests
hub:turnPage(1); assert(hub.route.subpage == 2 and #requests == calls, "Local pages must not re-fetch")
tap("book"); assert(hub.route.kind == "detail")
hub:back(); assert(hub.route.kind == "search" and hub.route.subpage == 2, "Back must retain search position")
tap("tab", "books"); tap("tab", "discover")
assert(hub.route.kind == "search" and hub.route.subpage == 2, "Tabs must retain their last screen")
hub:action({kind = "scope", scope = "library"})
assert(requests[#requests].path:find("scope=library", 1, true), "Search filter must reach the backend")
hub:primary({title = "Frankenstein", authors = {"Mary Shelley"}, providerKey = "openLibrary", providerId = "OL123W", downloadUrl = "https://forbidden.invalid/"})
assert(hub.route.kind == "request_detail" and hub.state.body.status == "approved")
for _, call in ipairs(requests) do if call.method == "POST" then assert(not call.payload.downloadUrl, "Acquisition must remain server-side") end end
status = "available"; hub:load(); hub:load()
assert(completions == 1, "Ready transition should trigger one resync, not polling/repeated resyncs")
-- A request that finishes while another screen is open is still noticed and synced once.
hub:observe({{id = 90, title = "The Time Machine", status = "downloading"}})
assert(hub.watchTimer and plugin.settings.hub_watched_requests.items["90"], "Active requests must be followed and saved")
hub:navigate({kind = "home"})
request_list = {{id = 90, title = "The Time Machine", status = "available", bookId = 102}}
hub:checkWatched()
assert(completions == 2, "A watched request becoming ready must trigger one sync from any screen")
assert(next(plugin.settings.hub_watched_requests.items) == nil and hub.watchTimer == nil, "Finished requests stop being watched")
hub:checkWatched(); assert(completions == 2, "No repeated sync once a request is settled")
-- The open request page shows new progress without a manual refresh.
hub:navigate({kind = "request_detail", id = 91, request = {id = 91, title = "Walden", status = "downloading", progressPercent = 10}})
assert(plugin.settings.hub_watched_requests.items["91"], "Opening an active request follows it")
request_list = {{id = 91, title = "Walden", status = "downloading", progressPercent = 40}}
hub:checkWatched()
assert(hub.state.body.progressPercent == 40, "Background checks must update the visible request")
-- Background checks never queue behind or block the reader's actions.
local before_busy = #requests
hub.busy = true; hub:checkWatched(); hub.busy = false
assert(#requests == before_busy and hub.watchTimer, "A check while busy waits for the next turn")
hub.busy, hub.activeFetch = true, {method = "GET", path = "x", route = hub.route, quiet = true}
hub:fetch("POST", "/koreader/plugin/requests/91/cancel", {}, function() end)
assert(hub.pendingFetch and hub.pendingFetch[1] == "POST", "Actions wait for a background check instead of being refused")
hub.busy, hub.activeFetch, hub.pendingFetch = false, nil, nil
request_list = {}
-- Refused actions show the server's reason, not a generic network error.
hub:fetch("POST", "/koreader/plugin/requests/refused", {}, function() error("refused action ran") end)
assert(hub.state.error:find("Not allowed", 1, true) and hub.state.error:find("permission to request books", 1, true), "Show why an action was refused")
hub:navigate({kind = "request_detail", id = 77, request = {id = 77, title = "Frankenstein", status = status}})
local delivery_calls, opened = 0
hub.catalog.fetchDeliveryBook = function(_, id) delivery_calls = delivery_calls + 1; return {id = id, title = "Public-domain title", authors = {}, files = {}} end
require("bookorbit_download_sheet").open = function(_, detail, opts) opened = {detail = detail, opts = opts} end
hub:primary({bookId = 101, title = "Public-domain title"})
assert(delivery_calls == 1 and opened.opts.start, "One-tap delivery must reuse the existing preference-aware downloader")
hub.state.body.replacementBookId = 101; hub:refreshView(); paint()
local replacement_action
for _,hit in ipairs(hub.page.hits) do
    if hit.action and hit.action.kind == "swap" then replacement_action = true end
    assert(not (hit.action and hit.action.kind == "primary"), "A ready replacement must not open the old local file")
end
assert(replacement_action, "A ready replacement must offer the existing safe swap downloader")
local old_menu = hub.menu
hub.menu = function(_, _, rows) rows[2].callback() end
local before_book_change = #requests
hub:changeFile({bookId=101})
assert(requests[before_book_change+1].path:find("requests/book/101/replacement",1,true), "Library Change file must use a direct manual replacement")
hub.menu = old_menu
local before_change = #requests
hub:changeFile({bookId=101}, {id=77})
assert(hub.route.kind == "releases" and hub.route.id == 78, "Change file must open the manual picker")
for i=before_change+1,#requests do
    assert(not requests[i].path:find("/retry",1,true) and not requests[i].path:find("/grab",1,true), "Opening the replacement picker must not acquire a release")
end
hub:navigate({kind="discover"});tap("roulette")
paint()
assert(hub.state.scrolling==nil and hub.state.measuredBodyHeight<=hub.state.bodyBounds.h,"Roulette controls must fit without scrolling")
local decision_calls=#requests
tap("roulette_decide")
assert(requests[decision_calls+1].path:match("roulette/decision$"),"Pass must save feedback, not request a book")
for i=decision_calls+1,#requests do assert(not requests[i].path:match("requests$"),"Feedback must never start acquisition") end
tap("roulette_undo");tap("matches")
assert(hub.route.kind=="matches" and hub.state.visible[1].matchKey,"Matches must be separate from library books")
tap("match_select");tap("match_toggle")
assert(hub.state.selectedCount==1,"Bulk selection must retain the match key")
hub.selectingMatches=false;hub:refreshView();tap("book")
assert(hub.state.book.matchKey,"Loading external detail must retain match membership")
local acquisition_start=#requests
tap("primary")
assert(requests[acquisition_start+1].path:match("roulette/acquire$"),"Add to Library must use the explicit acquisition endpoint")
assert(plugin.settings.hub_watched_requests.items["77"], "Requests created from Matches must be followed")
-- Offline, a Roulette decision moves to the next card at once and waits in the outbox.
local Roulette = require("bookorbit_roulette")
local Outbox = require("bookorbit_hub_outbox")
hub:navigate({kind = "roulette"})
assert(hub.state.book and hub.state.remaining == 1, "The saved deck shows its first card")
connected = false
local offline_start = #requests
tap("roulette_decide")
assert(#requests == offline_start, "Offline decisions must not try the network")
assert(Outbox.count(hub) == 1 and hub.state.book == nil, "The decided card leaves the deck while its decision waits")
Roulette.undo(hub)
assert(Outbox.count(hub) == 0 and hub.state.book ~= nil, "Undo of a waiting decision drops it and brings the card back")
tap("roulette_decide")
connected = true
Outbox.drain(hub)
local delivered
for i = offline_start + 1, #requests do if requests[i].path:match("roulette/decision$") then delivered = requests[i] end end
assert(delivered and delivered.payload.eventId and Outbox.count(hub) == 0, "Waiting decisions go out once BookOrbit can be reached")
-- Wishlist changes made offline are queued the same way.
hub:navigate({kind = "detail", book = {title = "Walden", authors = {"Henry David Thoreau"}, providerKey = "openLibrary", providerId = "OL1W"}})
connected = false
hub:action({kind = "save_wishlist", book = hub.state.book})
assert(Outbox.count(hub) == 1 and Outbox.items(hub)[1].path:match("hub/wishlist$"), "An offline wishlist change waits in the outbox")
connected = true
Outbox.drain(hub)
assert(Outbox.count(hub) == 0 and requests[#requests].path:match("hub/wishlist$"), "It is sent when back online")
-- A cover that arrives repaints only its own rectangle.
hub:navigate({kind = "home"}); paint()
local regions, refresh_before = {}, hub.page.refresh
hub.page.refresh = function(page, mode, region) regions[#regions + 1] = region or false; return refresh_before(page, mode, region) end
hub.visibleCovers = {{hub_cover_key = "cover-key", hasCover = true}}
hub.state.coverRects = {["cover-key"] = Geom:new{x = 60, y = 400, w = 80, h = 120}}
local cached_path = hub.catalog.cachedThumbnailPath
hub.catalog.cachedThumbnailPath = function(_, b) return b.hub_cover_key == "cover-key" and "/nonexistent-cover.jpg" or nil end
hub:coversArrived(); assert(hub.coverTimer, "Covers arriving together are coalesced"); hub.coverTimer()
assert(#regions == 1 and regions[1] and regions[1].w == 80 and regions[1].h == 120, "Only the arrived cover is refreshed")
hub.catalog.cachedThumbnailPath = cached_path
-- A page that did not change answers 304, and only the notice line repaints.
local books_path = hub:path({kind = "books", page = 1})
etags[books_path] = 'W/"books"'
hub:navigate({kind = "books", page = 1}); paint()
hub:navigate({kind = "home"}); paint()
regions = {}
-- On a Kobo the screen repaints while a request is in flight.
local plain_run = client.runInSubprocess
client.runInSubprocess = function(self, fn) paint(); return plain_run(self, fn) end
hub:navigate({kind = "books", page = 1}); paint()
client.runInSubprocess = plain_run
local revalidation = requests[#requests]
assert(revalidation.headers and revalidation.headers["if-none-match"] == 'W/"books"', "A saved page is revalidated with its tag")
local full = 0
for _, region in ipairs(regions) do if not region then full = full + 1 end end
assert(full == 1 and #regions == 2 and regions[2] and regions[2].h < 100, "An unchanged page repaints only its notice line")
assert(not hub.state.cached, "The saved copy counts as current after a 304")
etags[books_path] = nil
hub.page.refresh = refresh_before
-- Stats, Friends, Hub options and Diagnostics render within the screen.
hub:action({kind = "stats"}); paint()
assert(hub.route.kind == "stats" and hub.state.body.minutes.week == 140, "Stats load from the hub endpoint")
hub:action({kind = "social"}); paint()
assert(hub.state.visible[1].hint:find("Bea recommends", 1, true), "Friends show who recommends what")
hub:action({kind = "share_toggle"})
assert(requests[#requests - 1].path:match("social/sharing$") and requests[#requests - 1].payload.share == false, "The sharing switch flips the current state")
hub:action({kind = "hub_settings"}); paint()
local before_option = plugin.settings.hub_cleanup_days
hub:action({kind = "hub_option", key = "hub_cleanup_days"})
assert(before_option == nil and plugin.settings.hub_cleanup_days == 14, "Options cycle from their default")
plugin.settings.hub_cleanup_days = nil
hub:action({kind = "diagnostics"}); paint()
assert(hub.state.diag and hub.state.diag.cache, "Diagnostics show cache state")
hub:close()
local original_document={position=42,annotations={"preserved"}}
plugin.ui={document=original_document}
hub=Hub.open(plugin,true,{kind="home"});tap("resume_reading")
assert(hub.closed and plugin.ui.document==original_document and original_document.position==42 and original_document.annotations[1]=="preserved","Return and resume must keep the live document and reading state")
plugin.ui=nil
connected = false
hub = Hub.open(plugin, true, {kind = "books", filter = "local"})
assert(#hub.state.body.items == 1 and connection_prompts == 0, "On-device library must open without a connection prompt")
tap("book"); assert(hub.state.book.localPath == offline_file and connection_prompts == 0)
local read_path
hub.catalog.openDownloadedFile = function(_, path) read_path = path end
tap("primary"); assert(read_path == offline_file, "Offline Read must open the existing file")
paint()
for _, hit in ipairs(hub.page.hits) do
    if hit.dimen and hit.action and hit.action.kind == "tab" and hit.dimen.y > 1200 then
        assert(hit.dimen.y >= hub.state.bodyBounds.y + hub.state.bodyBounds.h, "Body must not overlap bottom navigation")
    end
end
for i = hub.state.bodyHitFirst, hub.state.bodyHitLast do
    local hit = hub.page.hits[i]
    if hit.dimen then assert(hit.dimen.y >= hub.state.bodyBounds.y and hit.dimen.y + hit.dimen.h <= hub.state.bodyBounds.y + hub.state.bodyBounds.h, "Scrolled body target leaked into navigation") end
end
hub.page:setApi({server_url = "https://fixture.invalid", username = "another-reader", userkey = "fixture"})
assert(hub.closed and plugin.catalog_browser == nil, "Changing accounts must close the previous user's visible state")
os.remove(offline_file)
print("Native Hub navigation, search, request, delivery, resync and offline tests passed")
