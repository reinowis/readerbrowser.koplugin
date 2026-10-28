--[[--
HTTP(S) fetching for Reader Browser, with manual redirect handling
(LuaSocket will not follow redirects between http and https).
]]

local RBHtml = require("rb_html")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local RBFetch = {
    user_agent = "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
    max_redirects = 8,
}

--- Fetches a URL.
-- @param url string
-- @param opts table|nil { body = string (sends a form POST) }
-- @return { code=, headers=, body=, url= (final, after redirects) } or nil, error message
function RBFetch.get(url, opts)
    opts = opts or {}
    local method, body = opts.body and "POST" or "GET", opts.body
    for _ = 1, RBFetch.max_redirects do
        local sink = {}
        local headers = {
            ["user-agent"] = RBFetch.user_agent,
            ["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["accept-language"] = "en-US,en;q=0.8",
        }
        local request = {
            url = url,
            method = method,
            redirect = false,
            headers = headers,
            sink = socketutil.table_sink(sink),
        }
        if body then
            headers["content-type"] = "application/x-www-form-urlencoded"
            headers["content-length"] = tostring(#body)
            request.source = ltn12.source.string(body)
        end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local code, resp_headers, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        if type(code) ~= "number" or not resp_headers then
            logger.warn("ReaderBrowser: request failed", url, code, status)
            if code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE then
                return nil, "The server took too long to respond."
            elseif code == socketutil.SSL_HANDSHAKE_CODE then
                return nil, "Secure connection failed."
            end
            return nil, tostring(status or code or "Network or server unavailable.")
        end

        local location = resp_headers.location
        if code >= 300 and code < 400 and location then
            url = RBHtml.resolveUrl(url, location) or location
            if code ~= 307 and code ~= 308 then
                method, body = "GET", nil
            end
        else
            return { code = code, headers = resp_headers, body = table.concat(sink), url = url }
        end
    end
    return nil, "Too many redirects."
end

return RBFetch
