package.path = arg[1] .. "/?.lua;" .. package.path
local R = require("rb_html")
local cases = {
 {"https://a.com/x/y/page.html?q=1", "other.html", "https://a.com/x/y/other.html"},
 {"https://a.com/x/y/page.html", "../z.html#f", "https://a.com/x/z.html#f"},
 {"https://a.com/x/y/", "./b/c", "https://a.com/x/y/b/c"},
 {"https://a.com", "b", "https://a.com/b"},
 {"https://a.com/p?x=1", "?y=2", "https://a.com/p?y=2"},
 {"https://a.com/p", "//cdn.b.com/s", "https://cdn.b.com/s"},
 {"https://a.com/p", "/root?a=1&amp;b=2", "https://a.com/root?a=1&b=2"},
 {"https://a.com/p", "javascript:void(0)", nil},
 {"https://a.com/p", "mailto:x@y.z", "mailto:x@y.z"},
 {"https://a.com/a/b/c", "../../../../d", "https://a.com/d"},
}
local fail = 0
for _, c in ipairs(cases) do
  local got = R.resolveUrl(c[1], c[2])
  if got ~= c[3] then fail = fail + 1; print("FAIL", c[1], c[2], "got", got, "want", c[3]) end
end
print(fail == 0 and "all URL cases pass" or (fail .. " failures"))
