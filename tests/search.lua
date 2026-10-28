-- Checks search result parsing against sample pages.
-- Run from the plugin folder: luajit tests/search.lua
package.path = "./?.lua;" .. package.path
local RBHtml = require("rb_html")

local cases = {
    { "tests/samples/ddg_sample.html", "https://github.com/koreader/koreader" },
    { "tests/samples/lite_sample.html", "https://www.mobileread.com/forums/" },
    { "tests/samples/mojeek_sample.html", "https://koreader.rocks/" },
}
local fail = 0
for _, c in ipairs(cases) do
    local f = assert(io.open(c[1], "rb"))
    local results = RBHtml.parseSearchResults(RBHtml.parse(f:read("*a")))
    f:close()
    if #results ~= 1 or results[1].url ~= c[2] or results[1].snippet == "" then
        fail = fail + 1
        print("FAIL", c[1], #results, results[1] and results[1].url)
    end
end
print(fail == 0 and "all search cases pass" or (fail .. " failures"))
os.exit(fail == 0 and 0 or 1)
