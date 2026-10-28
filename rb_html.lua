--[[--
HTML parsing, article extraction and simplification for Reader Browser.

Pure Lua (no KOReader dependencies) so it can be tested off-device.

    local RBHtml = require("rb_html")
    local doc = RBHtml.parse(html_string)
    local page = RBHtml.render(doc, url, "reader") -- or "text"
    -- page.title, page.body (simplified HTML fragment), page.charset
]]

local RBHtml = {}

local function set(list)
    local t = {}
    for w in list:gmatch("%S+") do t[w] = true end
    return t
end

local VOID = set("area base br col embed hr img input keygen link meta param source track wbr")
-- Elements dropped with all their content while parsing.
local DROP = set("script style noscript template svg math iframe object embed canvas video audio "
    .. "picture img button input select textarea option datalist dialog map")
-- Raw-text elements: their content is not markup, skip straight to the end tag.
local RAWTEXT = set("script style noscript template textarea xmp iframe svg math title")
local CLOSES_P = set("address article aside blockquote details dialog div dl fieldset figcaption figure "
    .. "footer form h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section table ul li")
local BLOCK = set("address article aside blockquote details div dl dd dt fieldset figcaption figure footer "
    .. "form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p pre section table tbody thead tfoot tr td th ul")

-- Tags kept as-is in the output; anything else is unwrapped (children kept, tag dropped).
local KEEP = set("p h1 h2 h3 h4 h5 h6 ul ol li blockquote pre hr br dl dt dd table thead tbody tfoot tr td th "
    .. "caption figure figcaption code kbd samp var em strong b i u s del ins sub sup small mark q cite abbr a")
-- Containers rendered as <div>.
local AS_DIV = set("div section article main header footer aside nav center details summary address fieldset form hgroup")

-- Class/id hints for article extraction.
local UNLIKELY = { "comment", "community", "disqus", "footer", "menu", "remark", "rss", "share", "shoutbox",
    "sidebar", "skyscraper", "sponsor", "ad-break", "agegate", "pagination", "pager", "popup", "cookie",
    "newsletter", "related", "social", "banner", "subscribe", "masthead", "breadcrumb", "navbar", "promo",
    "outbrain", "taboola", "signup", "login", "modal", "toolbar", "navbox", "catlinks", "printfooter",
    "noprint", "mw-editsection", "mw-jump", "sistersitebox", "metadata" }
local MAYBE = { "and", "article", "body", "column", "content", "main", "shadow", "story", "post", "entry" }
local NEGATIVE = { "hidden", "banner", "combx", "comment", "com-", "contact", "foot", "footer", "footnote",
    "masthead", "media", "meta", "outbrain", "promo", "related", "scroll", "share", "shoutbox", "sidebar",
    "skyscraper", "sponsor", "shopping", "tags", "tool", "widget", "nav", "menu", "social", "subscribe", "ad-" }
local POSITIVE = { "article", "body", "content", "entry", "hentry", "h-entry", "main", "page", "pagination",
    "post", "text", "blog", "story", "prose" }

local function hasAny(s, words)
    for _, w in ipairs(words) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Entities
-- ---------------------------------------------------------------------------

local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
    mdash = "\226\128\148", ndash = "\226\128\147", hellip = "\226\128\166", rsquo = "\226\128\153",
    lsquo = "\226\128\152", rdquo = "\226\128\157", ldquo = "\226\128\156", middot = "\194\183",
    raquo = "\194\187", laquo = "\194\171", copy = "\194\169", bull = "\226\128\162" }

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    if cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return "?"
end

function RBHtml.decodeEntities(s)
    return (s:gsub("&(#?[%w]+);?", function(e)
        if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
            local n = tonumber(e:sub(3), 16)
            return n and utf8char(n)
        elseif e:sub(1, 1) == "#" then
            local n = tonumber(e:sub(2))
            return n and utf8char(n)
        end
        return NAMED[e]
    end))
end

function RBHtml.escape(s)
    return (s:gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- ---------------------------------------------------------------------------
-- URLs
-- ---------------------------------------------------------------------------

local function normalizePath(path)
    local out = {}
    for seg in (path .. "/"):gmatch("([^/]*)/") do
        if seg == ".." then
            if #out > 1 then table.remove(out) end
        elseif seg ~= "." then
            table.insert(out, seg)
        end
    end
    local p = table.concat(out, "/")
    if path:sub(-1) ~= "/" and p:sub(-1) == "/" then p = p:sub(1, -2) end
    if path:match("/%.%.?$") then p = p .. "/" end
    return p
end

--- Resolves href against base_url. Returns nil for links we cannot follow.
function RBHtml.resolveUrl(base_url, href)
    if not href then return nil end
    href = RBHtml.decodeEntities(href):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[\r\n\t]", "")
    if href == "" then return nil end
    local scheme = href:match("^(%a[%w+.%-]*):")
    if scheme then
        scheme = scheme:lower()
        if scheme == "javascript" or scheme == "data" then return nil end
        return href
    end
    local b_scheme, b_host, b_path = base_url:match("^(%a[%w+.%-]*)://([^/?#]*)([^#]*)")
    if not b_scheme then return href end
    if href:sub(1, 2) == "//" then return b_scheme .. ":" .. href end
    if href:sub(1, 1) == "#" then return b_scheme .. "://" .. b_host .. b_path .. href end
    if b_path == "" then b_path = "/" end
    if href:sub(1, 1) == "/" then
        return b_scheme .. "://" .. b_host .. href
    end
    local b_nq = b_path:gsub("%?.*$", "")
    if href:sub(1, 1) == "?" then return b_scheme .. "://" .. b_host .. b_nq .. href end
    local dir = b_nq:match("^(.*/)") or "/"
    local h_path, h_rest = href:match("^([^?#]*)(.*)$")
    return b_scheme .. "://" .. b_host .. normalizePath(dir .. h_path) .. h_rest
end

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

local function parseAttrs(s)
    local a = {}
    if not s or s == "" then return a end
    for k, v in s:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do a[k:lower()] = v end
    for k, v in s:gmatch("([%w_:%-]+)%s*=%s*'([^']*)'") do
        k = k:lower()
        if a[k] == nil then a[k] = v end
    end
    for k, v in s:gmatch("([%w_:%-]+)%s*=%s*([^%s\"'>][^%s>]*)") do
        k = k:lower()
        if a[k] == nil then a[k] = v end
    end
    for k in s:gmatch("%f[%w_:%-]([%w_:%-]+)%f[%s/>%z]") do
        k = k:lower()
        if a[k] == nil and (k == "hidden") then a[k] = "" end
    end
    return a
end

-- Finds the '>' ending a tag that starts at pos, skipping quoted attribute values.
local function findTagEnd(html, pos)
    local i = pos
    while true do
        local j = html:find("[>\"']", i)
        if not j then return nil end
        local ch = html:sub(j, j)
        if ch == ">" then return j end
        if html:sub(j - 1, j - 1):match("[=%s]") then
            local k = html:find(ch, j + 1, true)
            if not k then return nil end
            i = k + 1
        else
            i = j + 1
        end
    end
end

--- Parses an HTML string into a lenient DOM tree.
-- Nodes are tables { tag=, attrs=, children=, parent= }; text nodes are plain strings.
function RBHtml.parse(html)
    local lower = html:lower() -- same byte offsets as html (only ASCII is lowercased)
    local root = { tag = "#root", attrs = {}, children = {} }
    local doc = { root = root, head = {} }
    local stack = { root }
    local n = #html
    local pos = 1

    local function current() return stack[#stack] end
    local function addText(t)
        if t ~= "" then table.insert(current().children, t) end
    end
    local function popTo(i)
        for j = #stack, i, -1 do stack[j] = nil end
    end
    -- Closes the nearest open `tag` (any of names) without crossing a `barrier` element.
    local function closeImplied(names, barriers)
        for i = #stack, 2, -1 do
            local t = stack[i].tag
            if names[t] then popTo(i) return end
            if barriers[t] then return end
        end
    end
    local P_BARRIER = set("button table td th div section article blockquote li")
    local P_ONLY = { p = true }
    local LI_ONLY, LI_BARRIER = { li = true }, set("ul ol menu")
    local DTDD, DTDD_BARRIER = set("dt dd"), set("dl")
    local TR, TR_BARRIER = set("tr td th"), set("table tbody thead tfoot")
    local TD, TD_BARRIER = set("td th"), set("tr table")

    while pos <= n do
        local lt = html:find("<", pos, true)
        if not lt then addText(html:sub(pos)) break end
        if lt > pos then addText(html:sub(pos, lt - 1)) end
        local c = html:sub(lt + 1, lt + 1)
        if html:sub(lt, lt + 3) == "<!--" then
            local e = html:find("-->", lt + 4, true)
            pos = e and e + 3 or n + 1
        elseif c == "!" or c == "?" then
            local e = html:find(">", lt, true)
            pos = e and e + 1 or n + 1
        elseif c == "/" then
            local e = html:find(">", lt, true)
            if not e then break end
            local name = lower:match("^</%s*([%w:%-]+)", lt)
            pos = e + 1
            if name and not (name == "body" or name == "html") then
                for i = #stack, 2, -1 do
                    if stack[i].tag == name then popTo(i) break end
                end
            end
        elseif c:match("%a") then
            local e = findTagEnd(html, lt + 1)
            if not e then addText(html:sub(lt)) break end
            local name = lower:match("^<([%w:%-]+)", lt)
            local attr_str = html:sub(lt + 1 + #name, e - 1)
            local self_closing = attr_str:sub(-1) == "/"
            pos = e + 1
            if RAWTEXT[name] then
                local s = lower:find("</" .. name, pos, true)
                local content = html:sub(pos, (s or n + 1) - 1)
                if name == "title" then doc.title = doc.title or content end
                if s then
                    local e2 = html:find(">", s, true)
                    pos = e2 and e2 + 1 or n + 1
                else
                    pos = n + 1
                end
            elseif name == "meta" or name == "base" or name == "link" then
                table.insert(doc.head, { tag = name, attrs = parseAttrs(attr_str) })
            elseif DROP[name] then
                if not VOID[name] and not self_closing then
                    local s = lower:find("</" .. name, pos, true)
                    if s then
                        local e2 = html:find(">", s, true)
                        pos = e2 and e2 + 1 or n + 1
                    end
                end
            elseif name == "html" or name == "head" or name == "body" then
                if name == "body" then doc.body_attrs = parseAttrs(attr_str) end
            else
                if CLOSES_P[name] then closeImplied(P_ONLY, P_BARRIER) end
                if name == "li" then closeImplied(LI_ONLY, LI_BARRIER)
                elseif name == "dt" or name == "dd" then closeImplied(DTDD, DTDD_BARRIER)
                elseif name == "tr" then closeImplied(TR, TR_BARRIER)
                elseif name == "td" or name == "th" then closeImplied(TD, TD_BARRIER)
                end
                local parent = current()
                local node = { tag = name, attrs = parseAttrs(attr_str), children = {}, parent = parent }
                table.insert(parent.children, node)
                if not VOID[name] and not self_closing then
                    table.insert(stack, node)
                end
            end
        else
            addText("<")
            pos = lt + 1
        end
    end

    for _, m in ipairs(doc.head) do
        local a = m.attrs
        if m.tag == "base" and a.href then doc.base_href = a.href end
        if m.tag == "meta" then
            if a.charset then doc.charset = a.charset:match("[%w_%-]+") end
            if a["http-equiv"] and a["http-equiv"]:lower() == "content-type" and a.content then
                doc.charset = doc.charset or a.content:match("charset=([%w_%-]+)")
            end
            local prop = (a.property or a.name or ""):lower()
            if prop == "og:title" and a.content then doc.og_title = a.content end
            if prop == "og:site_name" and a.content then doc.site_name = a.content end
        end
    end
    return doc
end

-- ---------------------------------------------------------------------------
-- Tree helpers
-- ---------------------------------------------------------------------------

local function isHidden(node)
    local a = node.attrs
    if a.hidden or a["aria-hidden"] == "true" then return true end
    local style = a.style
    if style then
        style = style:lower():gsub("%s", "")
        if style:find("display:none", 1, true) or style:find("visibility:hidden", 1, true) then return true end
    end
    return false
end

local function classId(node)
    if node._cid == nil then
        node._cid = ((node.attrs.class or "") .. " " .. (node.attrs.id or "")):lower()
    end
    return node._cid
end

-- Visible text length of a node (whitespace collapsed), cached.
local function textLen(node)
    if type(node) == "string" then
        local s = node:gsub("&#?%w+;", "x"):gsub("%s+", " ")
        return #s
    end
    if node._tlen then return node._tlen end
    local len = 0
    if not isHidden(node) then
        for _, ch in ipairs(node.children) do len = len + textLen(ch) end
    end
    node._tlen = len
    return len
end

local function linkLen(node)
    if type(node) == "string" then return 0 end
    if node._llen then return node._llen end
    local len = 0
    if node.tag == "a" then
        len = textLen(node)
    else
        for _, ch in ipairs(node.children) do len = len + linkLen(ch) end
    end
    node._llen = len
    return len
end

local function linkDensity(node)
    local t = textLen(node)
    if t == 0 then return 0 end
    return linkLen(node) / t
end

local function commaCount(node)
    if type(node) == "string" then
        local _, c = node:gsub(",", "")
        return c
    end
    local c = 0
    for _, ch in ipairs(node.children) do c = c + commaCount(ch) end
    return c
end

local function hasBlockChild(node)
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" and BLOCK[ch.tag] then return true end
    end
    return false
end

local function walk(node, fn)
    for _, ch in ipairs(node.children) do
        if type(ch) == "table" then
            if fn(ch) ~= false then walk(ch, fn) end
        end
    end
end

local function plainText(node)
    if type(node) == "string" then return node end
    local parts = {}
    for _, ch in ipairs(node.children) do table.insert(parts, plainText(ch)) end
    return table.concat(parts)
end

local function cleanText(s)
    return (RBHtml.decodeEntities(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- ---------------------------------------------------------------------------
-- Article extraction (a compact take on the Readability algorithm)
-- ---------------------------------------------------------------------------

local function classWeight(node)
    local s = classId(node)
    if s == " " then return 0 end
    local w = 0
    if hasAny(s, NEGATIVE) then w = w - 25 end
    if hasAny(s, POSITIVE) then w = w + 25 end
    return w
end

local TAG_BASE = { div = 5, article = 10, main = 5, section = 3, pre = 3, td = 3, blockquote = 3,
    address = -3, ol = -3, ul = -3, dl = -3, dd = -3, dt = -3, li = -3, form = -3,
    h1 = -5, h2 = -5, h3 = -5, h4 = -5, h5 = -5, h6 = -5, th = -5 }

local function hasBoilerplateRole(node)
    local role = node.attrs.role
    return role == "navigation" or role == "complementary" or role == "banner" or role == "contentinfo"
        or role == "dialog" or role == "alert"
end

local function isUnlikely(node)
    if node.tag == "body" or node.tag == "article" or node.tag == "main" then return false end
    if hasBoilerplateRole(node) then return true end
    local s = classId(node)
    if s == " " then return false end
    return hasAny(s, UNLIKELY) and not hasAny(s, MAYBE)
end

local function findArticle(root)
    local scores = {}
    local candidates = {}
    local function initScore(node)
        if scores[node] == nil then
            scores[node] = (TAG_BASE[node.tag] or 0) + classWeight(node)
            table.insert(candidates, node)
        end
    end

    local scorable = {}
    walk(root, function(node)
        if isHidden(node) or isUnlikely(node) then
            node._skip = true
            return false
        end
        local t = node.tag
        if t == "nav" or t == "aside" or t == "footer" then
            node._skip = true
            return false
        end
        if t == "p" or t == "pre" or t == "td" or t == "blockquote"
            or ((t == "div" or t == "section") and not hasBlockChild(node)) then
            table.insert(scorable, node)
        end
    end)

    for _, node in ipairs(scorable) do
        local len = textLen(node)
        if len >= 25 then
            local score = 1 + commaCount(node) + math.min(math.floor(len / 100), 3)
            local ancestor, level = node.parent, 0
            while ancestor and ancestor.tag ~= "#root" and level < 3 do
                initScore(ancestor)
                local divider = level == 0 and 1 or (level == 1 and 2 or level * 3)
                scores[ancestor] = scores[ancestor] + score / divider
                ancestor, level = ancestor.parent, level + 1
            end
        end
    end

    local top, top_score = nil, 0
    for _, node in ipairs(candidates) do
        local s = scores[node] * (1 - linkDensity(node))
        scores[node] = s
        if s > top_score then top, top_score = node, s end
    end
    if not top then return nil end

    -- If the top candidate's parent holds most of the same text, prefer it (avoids
    -- picking just one of several sibling blocks of an article).
    local parent = top.parent
    while parent and parent.tag ~= "#root" and not parent._skip
        and textLen(top) < textLen(parent) * 0.66 and scores[parent] and scores[parent] > top_score * 0.75 do
        top, top_score = parent, scores[parent]
        parent = top.parent
    end

    -- Collect siblings that look like part of the article.
    local parts = {}
    parent = top.parent
    if not parent then return { top } end
    local threshold = math.max(10, top_score * 0.2)
    for _, sib in ipairs(parent.children) do
        if sib == top then
            table.insert(parts, sib)
        elseif type(sib) == "table" and not sib._skip then
            local s = scores[sib]
            if s and s >= threshold then
                table.insert(parts, sib)
            elseif sib.tag == "p" then
                local len, ld = textLen(sib), linkDensity(sib)
                if (len > 80 and ld < 0.25) or (len > 0 and len <= 80 and ld == 0 and commaCount(sib) > 0) then
                    table.insert(parts, sib)
                end
            end
        end
    end
    return parts, top
end

-- Whether a container inside the article is boilerplate to drop (link lists, share bars...).
local function isClutter(node)
    local t = node.tag
    if t == "nav" or t == "aside" or t == "footer" or t == "form" then return true end
    if hasBoilerplateRole(node) then return true end
    if not (t == "div" or t == "section" or t == "ul" or t == "ol" or t == "table" or t == "header"
        or t == "span" or t == "sup") then
        return false
    end
    local len = textLen(node)
    if isUnlikely(node) and len < 2000 then return true end
    if classWeight(node) < 0 and len < 500 then return true end
    local ld = linkDensity(node)
    if ld > 0.5 and len < 1500 then return true end
    if len == 0 and t ~= "table" and not node.attrs.id then
        return true -- empty wrapper
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Serialization to simplified HTML
-- ---------------------------------------------------------------------------

local function serialize(nodes, ctx, out)
    for _, node in ipairs(nodes) do
        if type(node) == "string" then
            -- Source text is already HTML-escaped; only guard stray '<'.
            table.insert(out, (node:gsub("<", "&lt;")))
        elseif not node._skip_out and not isHidden(node) and not (ctx.reader and isClutter(node)) then
            local t = node.tag
            local out_tag = KEEP[t] and t or (AS_DIV[t] and "div") or nil
            if t == "a" then
                local href = RBHtml.resolveUrl(ctx.base, node.attrs.href)
                if href then
                    local page_no_frag = ctx.url:gsub("#.*$", "")
                    if href:sub(1, #page_no_frag + 1) == page_no_frag .. "#" then
                        href = href:sub(#page_no_frag + 1)
                    end
                    table.insert(out, '<a href="' .. RBHtml.escape(href) .. '"')
                    if node.attrs.id then table.insert(out, ' id="' .. RBHtml.escape(node.attrs.id) .. '"') end
                    table.insert(out, ">")
                    serialize(node.children, ctx, out)
                    table.insert(out, "</a>")
                else
                    serialize(node.children, ctx, out)
                end
            elseif out_tag then
                table.insert(out, "<" .. out_tag)
                local a = node.attrs
                if a.id then table.insert(out, ' id="' .. RBHtml.escape(a.id) .. '"') end
                if (t == "td" or t == "th") then
                    if a.colspan then table.insert(out, ' colspan="' .. RBHtml.escape(a.colspan) .. '"') end
                    if a.rowspan then table.insert(out, ' rowspan="' .. RBHtml.escape(a.rowspan) .. '"') end
                end
                if t == "ol" and a.start then table.insert(out, ' start="' .. RBHtml.escape(a.start) .. '"') end
                if VOID[t] then
                    table.insert(out, "/>")
                else
                    table.insert(out, ">")
                    serialize(node.children, ctx, out)
                    table.insert(out, "</" .. out_tag .. ">")
                end
            else
                -- Unknown/inline wrapper (span, font, ...): keep an id anchor, then the content.
                if node.attrs.id then table.insert(out, '<a id="' .. RBHtml.escape(node.attrs.id) .. '"></a>') end
                serialize(node.children, ctx, out)
            end
        end
    end
end

--- Builds the simplified page.
-- @param doc  result of RBHtml.parse
-- @param url  page URL (after redirects)
-- @param mode "reader" (main article only) or "text" (whole page)
-- @return { title=, site=, body=, charset=, extracted=bool }
function RBHtml.render(doc, url, mode)
    local base = url
    if doc.base_href then base = RBHtml.resolveUrl(url, doc.base_href) or url end
    local title = doc.og_title or doc.title
    title = title and cleanText(title) or nil
    if title == "" then title = nil end

    local nodes, extracted = { doc.root }, false
    if mode == "reader" then
        local parts = findArticle(doc.root)
        if parts and #parts > 0 then
            local len = 0
            for _, p in ipairs(parts) do len = len + textLen(p) end
            if len >= 200 then
                nodes, extracted = parts, true
            end
        end
    end

    local out = {}
    serialize(nodes, { base = base, url = url, reader = extracted }, out)
    local body = table.concat(out)
    -- Collapse runs of empty containers and whitespace to keep the file small.
    body = body:gsub("%s*\n[%s\n]*", "\n")
    for _ = 1, 3 do
        local count
        body, count = body:gsub("<(%w+)>%s*</%1>", "")
        if count == 0 then break end
    end

    if not title then
        local h1
        walk(doc.root, function(node)
            if h1 then return false end
            if node.tag == "h1" then h1 = cleanText(plainText(node)) return false end
        end)
        title = h1 ~= "" and h1 or nil
    end

    return {
        title = title,
        site = doc.site_name and cleanText(doc.site_name) or url:match("^%a[%w+.%-]*://([^/?#]+)"),
        body = body,
        charset = doc.charset,
        extracted = extracted,
        has_h1 = body:find("<h1[ >]") ~= nil,
    }
end

-- ---------------------------------------------------------------------------
-- Search results (DuckDuckGo HTML / Lite)
-- ---------------------------------------------------------------------------

local function unwrapDdgLink(href)
    if not href then return nil end
    href = RBHtml.decodeEntities(href)
    local uddg = href:match("[?&]uddg=([^&]+)")
    if uddg then
        href = uddg:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    if href:sub(1, 2) == "//" then href = "https:" .. href end
    return href
end

--- Extracts results from a DuckDuckGo (html or lite) or Mojeek results page.
-- @return array of { title=, url=, snippet= }
function RBHtml.parseSearchResults(doc)
    local results = {}
    local last
    local function inMojeekResults(node)
        local p = node.parent
        while p do
            if p.attrs and (" " .. (p.attrs.class or "") .. " "):find(" results%-standard ") then return true end
            p = p.parent
        end
        return false
    end
    walk(doc.root, function(node)
        local cls = " " .. (node.attrs.class or "") .. " "
        if cls:find("result--ad", 1, true) or cls:find("result-sponsored", 1, true) then return false end
        local is_mojeek_title = node.tag == "a" and cls:find(" title ", 1, true) and inMojeekResults(node)
        if is_mojeek_title and last and last.url == node.attrs.href then return false end
        if node.tag == "a" and (cls:find(" result__a ", 1, true) or cls:find(" result-link ", 1, true)
            or is_mojeek_title) then
            local u = unwrapDdgLink(node.attrs.href)
            if u and u:match("^https?://") and not u:find("duckduckgo.com/y.js", 1, true) then
                last = { title = cleanText(plainText(node)), url = u, snippet = "" }
                table.insert(results, last)
            end
            return false
        end
        if last and (cls:find(" result__snippet ", 1, true) or cls:find(" result-snippet ", 1, true)
            or (node.tag == "p" and cls == " s ")) then
            last.snippet = cleanText(plainText(node))
            return false
        end
    end)
    return results
end

return RBHtml
