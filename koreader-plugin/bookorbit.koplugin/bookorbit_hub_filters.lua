-- Filters & sort sheet for hub lists. Every filter is a route field, so the
-- server does the filtering and a filtered list pages like any other.
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")

local Filters = {}

local function apply(hub, key, value)
    local r = {}
    for k, v in pairs(hub.route) do
        r[k] = v
    end
    r[key] = value ~= "" and value or nil
    if key == "readStatus" then
        r.filter = nil
    end
    r.page, r.subpage, r.displayPage, r.scroll = 1, 1, 1, nil
    hub:navigate(r, true)
end

function Filters.text(hub, key, title)
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = hub.route[key] or "",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Apply",
                    is_enter_default = true,
                    callback = function()
                        local value = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        apply(hub, key, value)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Genres that books in this library actually carry, most common first.
function Filters.genres(hub, library_only)
    hub:fetch("GET", "/koreader/plugin/hub/genres", nil, function(body)
        local rows = {
            {
                text = "Any genre",
                callback = function()
                    apply(hub, "genre", "")
                end,
            },
        }
        for _, g in ipairs(body.items or {}) do
            if g.inLibrary or not library_only then
                local name = g.name
                local count = (g.count or 0) > 0 and (" · " .. g.count) or ""
                rows[#rows + 1] = {
                    text = name .. count,
                    callback = function()
                        apply(hub, "genre", name)
                    end,
                }
            end
        end
        rows[#rows + 1] = {
            text = "Type a genre…",
            callback = function()
                Filters.text(hub, "genre", "Genre (blank clears)")
            end,
        }
        hub:menu("Genre", rows)
    end)
end

function Filters.open(hub)
    local r, rows = hub.route, {}
    local function choices(label, key, values)
        rows[#rows + 1] = {
            text = label .. ": " .. (r[key] or "Any"),
            callback = function()
                local items = {}
                for _, item in ipairs(values) do
                    local name, value = item[1], item[2]
                    items[#items + 1] = {
                        text = name,
                        callback = function()
                            apply(hub, key, value)
                        end,
                    }
                end
                hub:menu(label, items)
            end,
        }
    end
    local function text(label, key)
        rows[#rows + 1] = {
            text = label .. (r[key] and (": " .. r[key]) or "…"),
            callback = function()
                Filters.text(hub, key, label .. " (blank clears)")
            end,
        }
    end
    local function genre(library_only)
        rows[#rows + 1] = {
            text = "Genre: " .. (r.genre or "Any"),
            callback = function()
                Filters.genres(hub, library_only)
            end,
        }
    end

    if r.kind == "books" and r.filter == "local" then
        hub:menu("On-device books", {
            {
                text = "Wishlist",
                callback = function()
                    hub:navigate({ kind = "wishlist" })
                end,
            },
            {
                text = "Collections",
                callback = function()
                    hub:navigate({ kind = "collections" })
                end,
            },
            {
                text = "Download settings",
                callback = function()
                    hub.plugin:openSettings(hub.catalog, "downloads")
                end,
            },
        })
        return
    end
    if r.kind == "books" then
        text("Search this library", "q")
        rows[#rows + 1] = {
            text = "Browse authors",
            callback = function()
                hub:navigate({ kind = "author_list" })
            end,
        }
        rows[#rows + 1] = {
            text = "Browse series",
            callback = function()
                hub:navigate({ kind = "series_list" })
            end,
        }
        text("Author (exact name)", "author")
        text("Series", "series")
        genre(true)
        choices(
            "Reading status",
            "readStatus",
            { { "Any", "" }, { "Unread", "unread" }, { "Reading", "reading" }, { "Finished", "finished" } }
        )
        choices(
            "Format",
            "format",
            { { "Any", "" }, { "EPUB", "epub" }, { "PDF", "pdf" }, { "KEPUB", "kepub" }, { "MOBI", "mobi" } }
        )
        choices("Sort", "sort", {
            { "Recently added", "recently_added" },
            { "Recently read", "recently_read" },
            { "Title", "title" },
            { "Author", "author" },
            { "Series order", "series" },
        })
        rows[#rows + 1] = {
            text = "Wishlist",
            callback = function()
                hub:navigate({ kind = "wishlist" })
            end,
        }
        rows[#rows + 1] = {
            text = "Collections",
            callback = function()
                hub:navigate({ kind = "collections" })
            end,
        }
    else
        if r.kind == "search" then
            choices("Search by", "field", {
                { "All fields", "all" },
                { "Title", "title" },
                { "Author", "author" },
                { "Series", "series" },
                { "ISBN", "isbn" },
            })
            genre(false)
        else
            text("Title within this catalog", "refine")
        end
        choices("Sort", "sort", { { "Relevance / popular", "popular" }, { "Newest first", "new" } })
    end
    choices("Language", "language", {
        { "Any language", "" },
        { "English", "en" },
        { "French", "fr" },
        { "Spanish", "es" },
        { "German", "de" },
        { "Italian", "it" },
        { "Portuguese", "pt" },
    })
    rows[#rows + 1] = {
        text = "Clear filters",
        callback = function()
            hub:navigate(
                { kind = r.kind, q = r.kind ~= "books" and r.q or nil, mode = r.mode, scope = "all", page = 1 },
                true
            )
        end,
    }
    hub:menu("Filters & sort", rows)
end

return Filters
