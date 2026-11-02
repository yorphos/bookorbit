package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path
package.loaded["gettext"] = function(s) return s end
package.loaded["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
local shown, calls, opened, last_screen = {}, {}, nil, nil
local timer, synced = nil, 0
local function widget(_, opts) return opts end
package.loaded["ui/widget/menu"] = { new = widget }
package.loaded["ui/widget/confirmbox"] = { new = widget }
package.loaded["ui/widget/infomessage"] = { new = widget }
package.loaded["ui/widget/inputdialog"] = { new = function(_, opts)
    opts.getInputText = function() return "Charles Dickens" end
    opts.onShowKeyboard = function() end
    return opts
end }
package.loaded["ui/uimanager"] = { show = function(_, w) shown[#shown + 1] = w end, close = function() end, scheduleIn = function(_, _, fn) timer = fn end, unschedule = function(_, fn) if timer == fn then timer = nil end end }
package.loaded["ui/network/manager"] = { runWhenConnected = function(_, fn) fn() end }
package.loaded["ui/trapper"] = { wrap = function(_, fn) fn() end }
local candidate = { title = "A Christmas Carol", authors = { "Charles Dickens" }, providerKey = "openlibrary", providerId = "OL1", availability = {} }
local current = { id = 5, title = candidate.title, authors = candidate.authors, status = "pending" }
local failed_post, access_denied = false, false
local client = {}
function client:request(method, path, payload)
    calls[#calls + 1] = { method = method, path = path, payload = payload }
    if access_denied then return nil, 403 end
    if path:find("/options", 1, true) then return { automaticApproval = false } end
    if path:find("/search?", 1, true) then return { items = { candidate }, partial = false } end
    if path:find("/releases?", 1, true) then
        return { items = {{ releaseId = string.rep("a", 64), title = "Carol EPUB", format = "epub", language = "en", source = "Test source", triedBefore = true }}, pageSize = 20, total = 1 }
    end
    if path:find("/grab", 1, true) then current.status = "downloading"; return current end
    if method == "POST" then
        if failed_post then return nil, "timeout" end
        return { request = current, subscribed = false }
    end
    if path:find("?page=", 1, true) then return { items = { current }, total = 25, pageSize = 20 } end
    return current
end
function client:runInSubprocess(fn)
    local body, err = fn()
    return true, { body = body, err = err }
end
package.loaded["bookorbit_api"] = { new = function() return client end }
local Requests = require("bookorbit_requests")
local plugin = {
    onBookOrbitDownloadComplete = function() synced = synced + 1 end,
    apiOpts = function() return { username = "device-only", userkey = "device-key" } end,
    openBookDetails = function(_, id) opened = id end,
    openReplacement = function(_, id, old_id) opened = { id, old_id } end,
    openBookOrbit = function() opened = "library" end,
}
local function click(screen, label)
    for _, row in ipairs(screen.menu.item_table) do
        if row.text == label then screen.menu:onMenuSelect(row); return end
    end
    error("Missing menu action: " .. label)
end
local function countPosts()
    local n = 0
    for _, call in ipairs(calls) do if call.method == "POST" then n = n + 1 end end
    return n
end

last_screen = Requests.open(plugin)
assert(last_screen.menu.title == "Find and request books")
click(last_screen, "Search by author")
local input = shown[#shown]
input.buttons[1][2].callback()
assert(calls[#calls].path:find("q=Charles%20Dickens&field=author", 1, true))
last_screen.menu:onMenuSelect(last_screen.menu.item_table[2])
local confirm = shown[#shown]
assert(confirm.text:find("administrator must approve", 1, true))
confirm.ok_callback()
assert(countPosts() == 1)
local payload = calls[#calls].payload
assert(payload.title == candidate.title and payload.language == "en" and payload.availability == nil and payload.selfServe == nil)
assert(last_screen.menu.item_table[1].text == "Waiting for administrator approval")
current.status = "downloading"; current.progressPercent = 41
click(last_screen, "Refresh status")
assert(last_screen.menu.item_table[1].text == "Downloading (41%)")
current.status = "available"; current.bookId = 90
assert(timer, "Active download must schedule status refresh")
local fire = timer; timer = nil; fire()
assert(synced == 1 and timer == nil, "Completion syncs once and stops polling")
click(last_screen, "Refresh status")
assert(synced == 1, "Refreshing a completed request must not sync again")
click(last_screen, "Open in library / Download")
assert(opened == 90 and last_screen.closed)

last_screen = Requests.open(plugin)
click(last_screen, "My requests")
click(last_screen, "More requests")
assert(calls[#calls].path:find("?page=2", 1, true))
click(last_screen, "Previous requests")
assert(calls[#calls].path:find("?page=1", 1, true))

local before = countPosts()
candidate.availability = { existingRequestId = 5, alreadySubscribed = true }
last_screen:select(candidate)
assert(countPosts() == before and last_screen.menu.title == candidate.title)
candidate.availability = {}
failed_post = true
last_screen:select(candidate)
shown[#shown].ok_callback()
assert(countPosts() == before + 1)
assert(shown[#shown].text:find("may have been saved", 1, true))
assert(not last_screen.busy)

failed_post = false
current.status = "failed"; current.canChooseRelease = true
last_screen:showDetail(current)
click(last_screen, "Try another release")
assert(last_screen.menu.title == "Choose a release")
local releaseRow = last_screen.menu.item_table[2]
assert(releaseRow.text:find("Previously tried", 1, true))
last_screen.menu:onMenuSelect(releaseRow)
shown[#shown].ok_callback()
assert(calls[#calls].payload.releaseId == string.rep("a", 64))
assert(calls[#calls].payload.releaseGuid == nil and calls[#calls].payload.indexerId == nil)
last_screen:close()
assert(timer == nil, "Closing the screen stops monitoring")

current.status = "available"; current.canReplace = true; current.canChooseRelease = false
last_screen = Requests.open(plugin)
last_screen:showDetail(current)
click(last_screen, "Wrong language / Replace edition")
click(last_screen, "English")
assert(shown[#shown].text:find("current library and Kobo copies stay", 1, true))
shown[#shown].ok_callback()
assert(calls[#calls].path:find("/replacement", 1, true) and calls[#calls].payload.language == "en")
assert(calls[#calls].payload.downloadUrl == nil)
last_screen:close()

current.replacementBookId = 89
last_screen = Requests.open(plugin)
last_screen:showDetail(current)
click(last_screen, "Download replacement / Swap copy")
assert(opened[1] == 90 and opened[2] == 89, "Swaps across separate library records without losing the old path")
current.replacementBookId = nil

access_denied = true
local denied = Requests.open(plugin)
assert(denied.menu == nil)
assert(shown[#shown].text:find("permission", 1, true))
print("KOReader requests: native search, approval, status, pagination, open, permissions and uncertain POST checks passed")
