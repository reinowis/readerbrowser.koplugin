--[[--
Reader Browser: browse the web as simplified pages read in KOReader.

Pages are fetched, simplified on the device (rb_html.lua) and written as small
HTML files in the cache folder, then opened with the normal reader. Links in
those pages open in the browser directly, and each page carries a toolbar of
"rb:" links (back, switch mode, new search, history, save).

@module koplugin.ReaderBrowser
]]

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local RBFetch = require("rb_fetch")
local RBHtml = require("rb_html")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/readerbrowser"
local MAX_CACHED_PAGES = 50
local MAX_HISTORY = 100

local ENGINES = {
    { id = "duckduckgo", name = _("DuckDuckGo"), url = "https://html.duckduckgo.com/html/?q=%s" },
    { id = "duckduckgo_lite", name = _("DuckDuckGo Lite"), url = "https://lite.duckduckgo.com/lite/?q=%s" },
    { id = "mojeek", name = _("Mojeek"), url = "https://www.mojeek.com/search?q=%s" },
}

-- Document types we offer to download and open instead of simplifying.
local DOC_TYPES = {
    ["application/pdf"] = "pdf",
    ["application/epub+zip"] = "epub",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw",
    ["image/vnd.djvu"] = "djvu",
    ["image/x-djvu"] = "djvu",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbz"] = "cbz",
}

local ReaderBrowser = WidgetContainer:extend{
    name = "readerbrowser",
    is_doc_only = false,
}

-- Raw HTML of the last fetched page, so switching mode does not refetch.
local last_raw = nil
-- Shared by the file manager and reader instances of the plugin.
local settings = nil

local function escape(s)
    return RBHtml.escape(s or "")
end

local function urlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function looksLikeUrl(s)
    if s:match("^%a[%w+.%-]*://") then return s end
    if not s:find("%s") and s:match("^[%w%-]+%.[%w%-%.]+[%w]") then
        return "https://" .. s
    end
end

function ReaderBrowser:init()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/readerbrowser.lua")
    end
    self.settings = settings
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.link and self.ui.document then
        self.ui.link:addToExternalLinkDialog("24_readerbrowser", function(this, link_url)
            return {
                text = _("Open in Reader Browser"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    self:navigate(link_url, self:getDefaultMode())
                end,
                show_in_dialog_func = function(url)
                    return url:match("^https?://") ~= nil
                end,
            }
        end)
        if self:isBrowserPage(self.ui.document.file) then
            self:hookLinks()
        end
    end
end

function ReaderBrowser:onDispatcherRegisterActions()
    Dispatcher:registerAction("readerbrowser_open", {
        category = "none",
        event = "ShowReaderBrowser",
        title = _("Reader Browser"),
        general = true,
    })
end

function ReaderBrowser:onShowReaderBrowser()
    self:showInputDialog()
    return true
end

-- Lets launcher plugins (e.g. Simple UI quick actions) open the browser.
function ReaderBrowser:show()
    self:showInputDialog()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function ReaderBrowser:getDefaultMode()
    return self.settings:readSetting("default_mode") or "reader"
end

function ReaderBrowser:getEngine()
    local id = self.settings:readSetting("engine") or "duckduckgo"
    for _, e in ipairs(ENGINES) do
        if e.id == id then return e end
    end
    return ENGINES[1]
end

function ReaderBrowser:addToHistory(url, title)
    local history = self.settings:readSetting("history") or {}
    for i = #history, 1, -1 do
        if history[i].url == url then table.remove(history, i) end
    end
    table.insert(history, 1, { url = url, title = title, time = os.time() })
    while #history > MAX_HISTORY do table.remove(history) end
    self.settings:saveSetting("history", history)
    self.settings:flush()
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function ReaderBrowser:addToMainMenu(menu_items)
    local engine_items = {}
    for _, e in ipairs(ENGINES) do
        table.insert(engine_items, {
            text = e.name,
            radio = true,
            checked_func = function() return self:getEngine().id == e.id end,
            callback = function()
                self.settings:saveSetting("engine", e.id)
                self.settings:flush()
            end,
        })
    end
    local function modeItem(mode, text)
        return {
            text = text,
            radio = true,
            checked_func = function() return self:getDefaultMode() == mode end,
            callback = function()
                self.settings:saveSetting("default_mode", mode)
                self.settings:flush()
            end,
        }
    end
    menu_items.readerbrowser = {
        text = _("Reader Browser"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Open Reader Browser"),
                callback = function() self:showInputDialog() end,
            },
            {
                text = _("History"),
                callback = function() self:showHistory() end,
            },
            {
                text_func = function() return T(_("Search engine: %1"), self:getEngine().name) end,
                sub_item_table = engine_items,
            },
            {
                text_func = function()
                    return T(_("Default mode: %1"), self:getDefaultMode() == "text" and _("Text") or _("Reader"))
                end,
                sub_item_table = {
                    modeItem("reader", _("Reader (main article only)")),
                    modeItem("text", _("Text (whole page)")),
                },
                separator = true,
            },
            {
                text = _("Clear history and cached pages"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Clear browsing history and cached pages?"),
                        ok_text = _("Clear"),
                        ok_callback = function() self:clearAll() end,
                    })
                end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Input dialog
-- ---------------------------------------------------------------------------

function ReaderBrowser:showInputDialog(prefill)
    local dialog
    local function go(mode)
        local input = util.trim(dialog:getInputText() or "")
        if input == "" then return end
        UIManager:close(dialog)
        local url = looksLikeUrl(input)
        if url then
            self:navigate(url, mode)
        else
            self:search(input, mode)
        end
    end
    dialog = InputDialog:new{
        title = _("Reader Browser"),
        input = prefill or "",
        input_hint = _("Search or enter a web address"),
        description = T(_("Searches with %1. Reader shows only the main article; Text shows the whole page."),
            self:getEngine().name),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("History"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showHistory()
                    end,
                },
            },
            {
                {
                    text = _("Text"),
                    callback = function() go("text") end,
                },
                {
                    text = _("Reader"),
                    is_enter_default = true,
                    callback = function() go("reader") end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Page files
-- ---------------------------------------------------------------------------

function ReaderBrowser:isBrowserPage(file)
    return file ~= nil and file:sub(1, #CACHE_DIR + 1) == CACHE_DIR .. "/"
end

-- Each page starts with a comment holding its metadata, so back/mode
-- switching keep working after KOReader restarts.
local function readMeta(file)
    if not file then return {} end
    local f = io.open(file, "rb")
    if not f then return {} end
    local head = f:read(4096) or ""
    f:close()
    local meta_str = head:match("<!%-%- rb%-meta (.-) %-%->")
    if not meta_str then return {} end
    local meta = {}
    for k, v in meta_str:gmatch('(%w+)="([^"]*)"') do
        meta[k] = RBHtml.decodeEntities(v)
    end
    return meta
end

local page_counter = 0

local function listPages()
    local files = {}
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then return files end
    for f in lfs.dir(CACHE_DIR) do
        if f:match("^page%-.*%.html$") then table.insert(files, CACHE_DIR .. "/" .. f) end
    end
    table.sort(files)
    return files
end

local function removePage(file)
    pcall(function() DocSettings:open(file):purge() end)
    os.remove(file)
end

function ReaderBrowser:currentFile()
    local doc = self.ui and self.ui.document
    return doc and doc.file
end

function ReaderBrowser:prunePages()
    local files = listPages()
    local current = self:currentFile()
    for i = 1, #files - MAX_CACHED_PAGES do
        if files[i] ~= current then removePage(files[i]) end
    end
end

--- Writes a page and returns its path.
-- @param meta table { url=, mode=, kind=, prev= }
function ReaderBrowser:writePage(meta, title, body_html, charset, toolbar)
    util.makePath(CACHE_DIR)
    page_counter = page_counter + 1
    local file = string.format("%s/page-%d-%03d.html", CACHE_DIR, os.time(), page_counter % 1000)
    local meta_parts = {}
    for _, k in ipairs({ "url", "mode", "kind", "prev" }) do
        if meta[k] then table.insert(meta_parts, k .. '="' .. escape(meta[k]) .. '"') end
    end
    local html = table.concat({
        "<!-- rb-meta ", table.concat(meta_parts, " "), " -->\n",
        "<!DOCTYPE html>\n<html><head>",
        '<meta http-equiv="Content-Type" content="text/html; charset=', escape(charset or "utf-8"), '"/>',
        "<title>", escape(title or meta.url or _("Web page")), "</title>",
        "<style>",
        ".rb-bar{font-size:0.8em;text-indent:0;text-align:left;margin:0 0 0.8em 0;padding-bottom:0.3em;",
        "border-bottom:1px solid black}",
        ".rb-bar.rb-bottom{border-bottom:none;border-top:1px solid black;margin:1.5em 0 0 0;padding-top:0.3em}",
        ".rb-bar a{text-decoration:none;font-weight:bold}",
        ".rb-src{font-size:0.75em;text-indent:0;text-align:left;margin-bottom:1em}",
        "pre{white-space:pre-wrap;font-size:0.85em}",
        "table{font-size:0.85em}",
        "</style></head><body>\n",
        '<div class="rb-bar">', toolbar, "</div>\n",
        body_html,
        '\n<div class="rb-bar rb-bottom">', toolbar, "</div>\n",
        "</body></html>\n",
    })
    local f = io.open(file, "wb")
    if not f then return nil end
    f:write(html)
    f:close()
    self:prunePages()
    return file
end

local function toolbarHtml(mode, kind)
    local items = { '<a href="rb:back">&lt; Back</a>' }
    if kind == "page" then
        table.insert(items, mode == "text"
            and '<a href="rb:mode">Reader mode</a>'
            or '<a href="rb:mode">Text mode</a>')
    end
    table.insert(items, '<a href="rb:new">Search</a>')
    table.insert(items, '<a href="rb:history">History</a>')
    if kind == "page" then
        table.insert(items, '<a href="rb:save">Save</a>')
    end
    return table.concat(items, " &#160;|&#160; ")
end

function ReaderBrowser:openFile(file)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        if ReaderUI.instance then
            ReaderUI.instance:switchDocument(file, true)
        else
            ReaderUI:showReader(file, nil, true)
        end
    end)
end

-- Browser pages should not show up as books in history / "currently reading".
function ReaderBrowser:onReaderReady()
    local file = self:currentFile()
    if self:isBrowserPage(file) then
        local ReadHistory = require("readhistory")
        ReadHistory:removeItemByPath(file)
        ReadHistory:ensureLastFile()
    end
end

-- ---------------------------------------------------------------------------
-- Links inside browser pages
-- ---------------------------------------------------------------------------

function ReaderBrowser:hookLinks()
    local link = self.ui.link
    local orig_onGotoLink = link.onGotoLink
    link.onGotoLink = function(this, l, neglect_current_location, allow_footnote_popup)
        local url = l and (l.xpointer or l.uri)
        if type(url) == "string" and (url:match("^rb:") or url:match("^https?://")) then
            local internal = not this.ui.paging and this.document:isXPointerInDocument(url)
            if not internal then
                self:onLink(url)
                return true
            end
        end
        return orig_onGotoLink(this, l, neglect_current_location, allow_footnote_popup)
    end
end

function ReaderBrowser:onLink(url)
    local file = self:currentFile()
    local meta = readMeta(file)
    local mode = meta.mode or self:getDefaultMode()
    if url == "rb:back" then
        if meta.prev and lfs.attributes(meta.prev, "mode") == "file" then
            self:openFile(meta.prev)
        else
            UIManager:show(InfoMessage:new{ text = _("This is the first page."), timeout = 2 })
        end
    elseif url == "rb:mode" then
        if meta.url then
            local new_mode = mode == "text" and "reader" or "text"
            self:navigate(meta.url, new_mode, { prev = meta.prev, replace = file })
        end
    elseif url == "rb:new" then
        self:showInputDialog()
    elseif url == "rb:history" then
        self:showHistory()
    elseif url == "rb:save" then
        self:savePage(file)
    elseif url == "rb:clearhistory" then
        UIManager:show(ConfirmBox:new{
            text = _("Clear browsing history?"),
            ok_text = _("Clear"),
            ok_callback = function()
                self.settings:saveSetting("history", {})
                self.settings:flush()
                self:showHistory()
            end,
        })
    else
        self:navigate(url, mode, { prev = file })
    end
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

--- Fetches, simplifies and opens a URL.
-- @param opts table|nil { prev = file of the previous page, replace = file being replaced }
function ReaderBrowser:navigate(url, mode, opts)
    opts = opts or {}
    if opts.prev == nil and self:isBrowserPage(self:currentFile()) then
        opts.prev = self:currentFile()
    end
    -- Switching mode on the page just fetched: no need to download it again.
    if last_raw and last_raw.url == url and opts.replace then
        self:showFetched(last_raw.res, mode, opts)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Loading…\n%1"), BD.url(url)) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local res, err = RBFetch.get(url)
        UIManager:close(info)
        if not res then
            UIManager:show(InfoMessage:new{ text = T(_("Could not load page:\n%1\n\n%2"), BD.url(url), err) })
            return
        end
        self:showFetched(res, mode, opts)
    end)
end

function ReaderBrowser:showFetched(res, mode, opts)
    local headers = res.headers
    local content_type = (headers["content-type"] or ""):lower()
    local mime = content_type:match("^%s*([^;%s]+)") or ""
    local encoding = (headers["content-encoding"] or ""):lower()
    if encoding ~= "" and encoding ~= "identity" then
        UIManager:show(InfoMessage:new{ text = T(_("The server sent a compressed page (%1), which is not supported."), encoding) })
        return
    end

    local ext = DOC_TYPES[mime]
    if not ext then
        local path_ext = res.url:match("^[^?#]*%.(%w+)$")
        path_ext = path_ext and path_ext:lower()
        if path_ext and (mime == "application/octet-stream" or mime == "")
            and (path_ext == "epub" or path_ext == "pdf" or path_ext == "mobi" or path_ext == "djvu"
                or path_ext == "cbz" or path_ext == "fb2" or path_ext == "azw3") then
            ext = path_ext
        end
    end
    if ext then
        self:saveDocument(res, ext)
        return
    end

    local body_html, title, charset, kind
    local header_charset = content_type:match("charset=([%w_%-]+)")
    if mime == "text/plain" then
        body_html = "<pre>" .. escape(res.body) .. "</pre>"
        title = res.url
        charset = header_charset
        kind = "page"
    elseif mime == "" or mime:find("html", 1, true) or mime:find("xml", 1, true) then
        local ok, page = pcall(function()
            return RBHtml.render(RBHtml.parse(res.body), res.url, mode)
        end)
        if not ok then
            logger.warn("ReaderBrowser: could not simplify page", res.url, page)
            UIManager:show(InfoMessage:new{ text = _("Could not read this page.") })
            return
        end
        title = page.title
        charset = header_charset or page.charset
        local header = {}
        if not page.has_h1 and title then table.insert(header, "<h1>" .. escape(title) .. "</h1>") end
        local note = ""
        if mode == "reader" and not page.extracted then
            note = " &#183; " .. escape(_("no article found, showing whole page"))
        end
        if res.code >= 400 then
            note = note .. " &#183; " .. escape(T(_("HTTP error %1"), res.code))
        end
        table.insert(header, '<p class="rb-src">' .. escape(page.site or "") .. " &#183; "
            .. escape(res.url) .. note .. "</p>")
        body_html = table.concat(header, "\n") .. "\n" .. page.body
        kind = "page"
    else
        UIManager:show(InfoMessage:new{ text = T(_("Cannot show this type of content:\n%1"), mime) })
        return
    end

    last_raw = { url = res.url, res = res }
    local file = self:writePage({ url = res.url, mode = mode, kind = kind, prev = opts.prev },
        title, body_html, charset, toolbarHtml(mode, kind))
    if not file then
        UIManager:show(InfoMessage:new{ text = _("Could not write page to the cache folder.") })
        return
    end
    if opts.replace then removePage(opts.replace) end
    self:addToHistory(res.url, title)
    self:openFile(file)
end

function ReaderBrowser:saveDocument(res, ext)
    local dir = G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("home_dir")
        or DataStorage:getDataDir()
    local name = res.url:match("^[^?#]*/([^/?#]+)$") or ("download." .. ext)
    local disposition = res.headers["content-disposition"]
    if disposition then
        name = disposition:match('filename="([^"]+)"') or disposition:match("filename=([^;]+)") or name
    end
    name = util.urlDecode(name)
    if not name:lower():match("%." .. ext .. "$") then name = name .. "." .. ext end
    local path = dir .. "/" .. util.getSafeFilename(name, dir)
    UIManager:show(ConfirmBox:new{
        text = T(_("This link is a document (%1).\n\nSave it to:\n%2"), ext:upper(), BD.filepath(path)),
        ok_text = _("Save and open"),
        ok_callback = function()
            local f = io.open(path, "wb")
            if not f then
                UIManager:show(InfoMessage:new{ text = _("Could not save the file.") })
                return
            end
            f:write(res.body)
            f:close()
            self:openFile(path)
        end,
    })
end

function ReaderBrowser:search(query, mode)
    local engine = self:getEngine()
    local url = string.format(engine.url, urlEncode(query))
    local prev = self:isBrowserPage(self:currentFile()) and self:currentFile() or nil
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Searching %1…\n%2"), engine.name, query) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local res, err = RBFetch.get(url)
        UIManager:close(info)
        if not res then
            UIManager:show(InfoMessage:new{ text = T(_("Search failed:\n%1"), err) })
            return
        end
        local ok, results = pcall(function() return RBHtml.parseSearchResults(RBHtml.parse(res.body)) end)
        if not ok or #results == 0 then
            -- Show the engine's own page so the user can see what happened (e.g. a bot check).
            UIManager:show(InfoMessage:new{
                text = T(_("No results could be read from %1. It may be asking to confirm you are human.\n\nTry again later, or pick another search engine in Menu → Reader Browser."), engine.name),
            })
            self:showFetched(res, "text", { prev = prev })
            return
        end
        local parts = {
            "<h1>" .. escape(query) .. "</h1>",
            '<p class="rb-src">' .. escape(T(_("%1 results from %2, opening in %3 mode"), #results, engine.name,
                mode == "text" and _("text") or _("reader"))) .. "</p>",
        }
        for _, r in ipairs(results) do
            table.insert(parts, '<h3><a href="' .. escape(r.url) .. '">' .. escape(r.title) .. "</a></h3>")
            if r.snippet ~= "" then table.insert(parts, "<p>" .. escape(r.snippet) .. "</p>") end
            table.insert(parts, '<p class="rb-src">' .. escape(r.url) .. "</p>")
        end
        local file = self:writePage({ url = url, mode = mode, kind = "search", prev = prev },
            query, table.concat(parts, "\n"), "utf-8", toolbarHtml(mode, "search"))
        if file then self:openFile(file) end
    end)
end

function ReaderBrowser:showHistory()
    local history = self.settings:readSetting("history") or {}
    local parts = { "<h1>" .. escape(_("History")) .. "</h1>" }
    if #history == 0 then
        table.insert(parts, "<p>" .. escape(_("No pages visited yet.")) .. "</p>")
    else
        table.insert(parts, "<ul>")
        for _, h in ipairs(history) do
            table.insert(parts, '<li><a href="' .. escape(h.url) .. '">' .. escape(h.title or h.url) .. "</a>"
                .. '<br/><span class="rb-src">' .. escape(os.date("%Y-%m-%d %H:%M", h.time)) .. " &#183; "
                .. escape(h.url:match("^%a+://([^/?#]+)") or h.url) .. "</span></li>")
        end
        table.insert(parts, "</ul>")
        table.insert(parts, '<p><a href="rb:clearhistory">' .. escape(_("Clear history")) .. "</a></p>")
    end
    local prev = self:isBrowserPage(self:currentFile()) and self:currentFile() or nil
    local file = self:writePage({ mode = self:getDefaultMode(), kind = "history", prev = prev },
        _("History"), table.concat(parts, "\n"), "utf-8", toolbarHtml(self:getDefaultMode(), "history"))
    if file then self:openFile(file) end
end

function ReaderBrowser:savePage(file)
    if not file then return end
    local f = io.open(file, "rb")
    if not f then return end
    local html = f:read("*a")
    f:close()
    local title = html:match("<title>(.-)</title>") or "Web page"
    title = RBHtml.decodeEntities(title)
    -- Saved copies have no toolbar: its links only work inside the browser.
    html = html:gsub('<div class="rb%-bar[^"]*">.-</div>\n?', "")
    local dir = (G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()) .. "/Web pages"
    util.makePath(dir)
    local path = dir .. "/" .. util.getSafeFilename(title .. ".html", dir)
    local out = io.open(path, "wb")
    if not out then
        UIManager:show(InfoMessage:new{ text = _("Could not save the page.") })
        return
    end
    out:write(html)
    out:close()
    UIManager:show(InfoMessage:new{ text = T(_("Saved to:\n%1"), BD.filepath(path)), timeout = 3 })
end

function ReaderBrowser:clearAll()
    self.settings:saveSetting("history", {})
    self.settings:flush()
    local current = self:currentFile()
    for _, file in ipairs(listPages()) do
        if file ~= current then removePage(file) end
    end
    last_raw = nil
    UIManager:show(InfoMessage:new{ text = _("History and cached pages cleared."), timeout = 2 })
end

return ReaderBrowser
