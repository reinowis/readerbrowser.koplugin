# Reader Browser for KOReader

Browse the web on your e-reader as clean, readable pages.

- **Reader mode** shows only the main article, without menus, ads or sidebars.
- **Text mode** shows the whole page as plain text.

Pages open in KOReader's normal reader, so your fonts, sizes, highlights and dictionary all work. Pages are simplified on the device itself; nothing is sent to third-party services.

## Features

- Type a web address, or search with DuckDuckGo, DuckDuckGo Lite or Mojeek.
- Tapping a link in a page opens it in the same mode.
- A bar at the top and bottom of every page: **Back · Text/Reader mode · Search · History · Save**.
- **Save** keeps a copy of the page in a `Web pages` folder in your home folder.
- Links in your books get an **Open in Reader Browser** button.
- Links to PDF, EPUB and other ebooks are offered as downloads, then open as books.
- Browsed pages stay out of your reading history. Only the last 50 pages are cached.
- Images are not shown.

## Installation

1. Download this repository and name the folder `readerbrowser.koplugin`.
2. Copy it into KOReader's `plugins` folder (on Kindle: `koreader/plugins/`).
3. Restart KOReader.
4. Open it from **Menu → Search → Reader Browser**.

The menu also lets you change the search engine and the default mode, and clear history and cached pages.

To open the browser from a gesture or a launcher plugin such as Simple UI, use the **Reader Browser** system action (`readerbrowser_open`).

## Search engines

Search engines sometimes ask simple clients to prove they're human. When that happens, the plugin says so and shows the engine's page. Try again later or switch engines.

## Development

The page simplifier (`rb_html.lua`) has no KOReader dependencies. Its tests run with LuaJIT from the plugin folder:

```sh
luajit tests/urls.lua .
luajit tests/search.lua
```

## Files

| File | Purpose |
| --- | --- |
| `main.lua` | Plugin UI, navigation, page files, history |
| `rb_html.lua` | HTML parsing, article extraction, simplification, search result parsing |
| `rb_fetch.lua` | HTTP(S) requests with redirect handling |
