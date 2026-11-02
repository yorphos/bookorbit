-- Opt-in live validation. Credentials come from a private file, never this source.
assert(os.getenv("BOOKORBIT_LIVE_TEST") == "1", "Explicit live-test opt-in required")
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/live-test.reader.lua")
G_reader_settings:saveSetting("sdl_window", {width = 1072, height = 1448})
package.path = os.getenv("BOOKORBIT_PLUGIN_DIR") .. "/?.lua;" .. package.path
local Device = require("device")
Device.screen:setDPI(300); Device.screen.dpi_override = nil
require("document/canvascontext"):init(Device)
require("bookorbit_board_metrics").setUserScale(1.05)
local util = require("util")
local secret = assert(io.open(os.getenv("BOOKORBIT_TEST_SECRET_FILE"))):read("*a"):gsub("%s+$", "")
local Api = require("bookorbit_api")
-- Synchronous transport for deterministic headless tests; HTTP and decoding are real.
Api.runInSubprocess = function(_, fn) local body, err, errbody = fn(); return true, {body = body, err = err, errbody = errbody} end
local Network = require("ui/network/manager")
Network.isConnected = function() return true end
Network.runWhenConnected = function(_, fn) fn() end
local Catalog = require("bookorbit_catalog")
Catalog.scheduleThumbnailDownloads = function() end
local dir = os.getenv("BOOKORBIT_PREVIEW_DIR")
local downloads = os.getenv("KO_HOME") .. "/downloads"
assert(util.makePath(downloads))
G_reader_settings:saveSetting("download_dir", downloads)
local opened_path, completed = nil, 0
local plugin = {path = os.getenv("BOOKORBIT_PLUGIN_DIR"), settings = {
    server_url = assert(os.getenv("BOOKORBIT_TEST_SERVER_URL"), "BOOKORBIT_TEST_SERVER_URL required"),
    username = assert(os.getenv("BOOKORBIT_TEST_USERNAME"), "BOOKORBIT_TEST_USERNAME required"), userkey = require("ffi/sha2").md5(secret),
    device_id = "bookorbit-native-validation-230", device_model = "KOReader Linux validation", plugin_version = "2.5.1",
    download_dir = downloads, download_folder = downloads,
}, ui = {openFile = function(_, path) opened_path = path end}}
secret = nil
function plugin:apiOpts() return self.settings end
function plugin:onBookOrbitDownloadComplete() completed = completed + 1 end
local Hub = require("bookorbit_hub")
local hub = Hub.open(plugin, false, {kind = "home"})
assert(not hub.state.error and hub.state.body.canRequest, "Live Home failed")
local bb = require("ffi/blitbuffer").new(1072, 1448, require("ffi/blitbuffer").TYPE_BB8)
hub.page:paintTo(bb, 0, 0); bb:writePNG(dir .. "/live-home.png")
if os.getenv("BOOKORBIT_REQUEST_PD") == "1" then
    hub:navigate({kind = "search", q = "The Time Machine", scope = "all", page = 1})
    local candidate
    for _, item in ipairs(hub.state.body.items or {}) do
        if item.title:lower() == "the time machine" and table.concat(item.authors or {}, " "):lower():find("wells", 1, true) and item.providerKey == "openLibrary" then candidate = item; break end
    end
    assert(candidate and not candidate.bookId, "Missing public-domain work not found")
    hub:primary(hub:prepare(candidate))
    assert(hub.route.kind == "request_detail" and hub.state.body.id, "Native request submission failed")
    local out = assert(io.open(dir .. "/live-request.json", "w")); out:write(require("rapidjson").encode(hub.state.body)); out:close()
    hub.page:paintTo(bb, 0, 0); bb:writePNG(dir .. "/live-request.png")
    print("Native public-domain request submitted:", hub.state.body.id, hub.state.body.status)
    hub:close(); os.exit(0)
end
local expected_id = tonumber(os.getenv("BOOKORBIT_TEST_BOOK_ID")) or 30
local title = os.getenv("BOOKORBIT_TEST_TITLE") or "A Tale of Two Cities"
hub:navigate(os.getenv("BOOKORBIT_TEST_MATCHES") == "1" and {kind="matches",q=title,page=1} or {kind = "search", q = title, scope = "library", page = 1})
assert(not hub.state.error and #hub.state.visible > 0, "Live library search failed")
local book
for _, item in ipairs(hub.state.body.items) do if item.bookId == expected_id then book = item end end
assert(book, "Public-domain test book missing")
hub:openBook(book)
assert(hub.state.book.language == "en", "Live metadata language was lost")
-- Fetch the real authenticated cover and render it with the native detail widget.
local image_file = dir .. "/live-cover.jpg"
local image_ok = hub.client:downloadBlocking("/koreader/plugin/catalog/books/" .. expected_id .. "/thumbnail", image_file, {max_bytes = 2000000})
if image_ok then hub.state.book.coverPath = image_file; hub.page:refresh() end
hub.page:paintTo(bb, 0, 0); bb:writePNG(dir .. "/live-detail.png")
local sheet
local DownloadSheet = require("bookorbit_download_sheet")
local real_open = DownloadSheet.open
DownloadSheet.open = function(...) sheet = real_open(...); return sheet end
hub:primary(hub.state.book)
assert(sheet and sheet.state == "done", "Native delivery did not finish: " .. tostring(sheet and sheet.state) .. " / " .. tostring(sheet and sheet.error_text))
assert(sheet.result.path and completed > 0, "Download must trigger resync")
local path = sheet.result.path
require("ui/uimanager").tickAfterNext = function(_, fn) fn() end
sheet:runAction({kind = "read"})
assert(opened_path == path, "Read action did not reach KOReader's file opener")
local document = assert(require("document/documentregistry"):openDocument(path), "KOReader could not open the downloaded EPUB")
document:loadDocument()
document:render()
local pages = document:getPageCount()
assert(pages and pages > 1, "EPUB was not rendered as a readable document")
document:gotoPage(math.min(7,pages))
local position=document:getXPointer()
plugin.ui.document=document
local return_hub=Hub.open(plugin,true,{kind="home"})
assert(return_hub.state.canResume,"An open reader must offer Resume Reading")
return_hub:action({kind="resume_reading"})
assert(return_hub.closed and plugin.ui.document==document and document:getXPointer()==position,"Return/resume must preserve the real EPUB engine position")
plugin.ui.document=nil
document:close()
local evidence = assert(io.open(dir .. "/live-native.json", "w"))
evidence:write(require("rapidjson").encode({bookId = expected_id, path = path, pages = pages, resyncCallbacks = completed, download = true, nativeDocumentOpen = true})); evidence:close()
print("Live native Home/search/detail/download/read passed; pages:", pages)
