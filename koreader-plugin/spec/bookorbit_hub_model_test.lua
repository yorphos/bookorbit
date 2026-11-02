package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path
package.loaded["bookorbit_board_metrics"] = { px = function(v) return v end, INK = {} }
local M = require("bookorbit_hub_model")

-- Progress steps
assert(M.step({ status = "pending" }) == 1 and select(2, M.step({ status = "pending" })) == true, "Pending waits at Requested")
assert(M.step({ status = "searching" }) == 2)
assert(M.step({ status = "downloading" }) == 3)
local reached, waiting = M.step({ status = "needs_review" })
assert(reached == 4 and waiting == true, "Review holds at Importing")
assert(M.step({ status = "available" }) == 5)
assert(M.step({ status = "failed" }) == nil, "Failed requests have no known step")
assert(M.isActive("downloading") and not M.isActive("pending") and not M.isActive("available"))
assert(M.isSettled("available") and M.isSettled("cancelled") and not M.isSettled("needs_review"))

-- Request payload: metadata only, English, ISBNs dropped for other-language editions
local payload = M.requestPayload({ title = "Walden", authors = { "Thoreau" }, isbn13 = "9780000000000", language = "fr", downloadUrl = "https://x.invalid", seriesIndex = "2" })
assert(payload.title == "Walden" and payload.language == "en" and payload.isbn13 == nil and payload.downloadUrl == nil and payload.seriesIndex == 2)
assert(M.requestPayload({ title = "Walden", isbn13 = "9780000000000", language = "en" }).isbn13 == "9780000000000")

-- Error text
local text = M.errorText("POST", true, 403, { message = "Your account does not have permission to request books" })
assert(text:find("^Not allowed: Your account does not have permission"), text)
assert(M.errorText("GET", true, 401):find("Reconnect", 1, true))
assert(M.errorText("POST", true, 400, { message = { "language must be a string", "other" } }) == "language must be a string")
assert(M.errorText("POST", true, 502, { message = "Sources could not be searched. Try again." }):find("Sources could not be searched", 1, true))
assert(M.errorText("POST", true, "network_error"):find("No reply", 1, true), "Lost POST replies warn about duplicates")
assert(M.errorText("GET", true, "network_error"):find("Can't reach", 1, true))
assert(M.errorText("POST", false):find("Cancelled", 1, true))
local long = M.serverMessage({ message = string.rep("é", 200) })
assert(#long <= 163 and long:sub(-3) == "…" and long:sub(1, -4):match("^[\195\169]+$") and #long:sub(1, -4) % 2 == 0, "Long messages are clipped on a UTF-8 boundary")
print("Hub model tests passed")
