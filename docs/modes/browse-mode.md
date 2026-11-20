# browse-mode and browsers-mode

`browse-mode` reads web pages as clean text inside compos, stripping site menus and clutter with per-host XSLT parsers. `browsers-mode` lists and controls the real Google Chrome windows and tabs seen through the compos Chrome extension.

## `browse-mode` (`M-x browse`)

| Key | What it does |
| --- | --- |
| `R` | Cycle reading mode: calm (article only), full document, or live page in this window |
| `RET` | Follow the link at point (on an index page, opens beside it) |
| `s-RET` / `M-RET` | Open link in a new tab / open beside this page as a child |
| `N` / `P` / `^` | On a child page from an index: next link, previous link, or back to index |
| `}` / `{` / `Tab` | Jump between links |
| `n` / `p` / `M-g i` | Jump by section or open section outline (`imenu`) |
| `l` / `M-<left>`, `r` / `M-<right>` | History back and forward (restores exact line) |
| `u` / `t` | Go to parent path / go to site root |
| `g` | Refetch this page or navigate to a URL |
| `o` / `w` / `v` / `d` | Open in real browser / copy URL / view raw HTML / download |
| `b` / `B` / `H` | Bookmark this page / list bookmarks / browse history |
| `M-x browse-learn-parser` | Learn or refresh the XSLT clutter-removal sheet for this host |

## `browsers-mode` (`M-x browsers`)

Requires the compos Chrome extension (`(browser-connected?)` -> `#t`). `<left>` and `<right>` step across All and each Chrome profile.

| Key | What it does |
| --- | --- |
| `RET` or `o` | Bring the Chrome tab to the front |
| `r` | Read the tab's content into a compos buffer |
| `k` | Close the tab (or every tab when on a window row) |
| `d` | Pin or unpin this group to the window's Chrome profile |
| `Tab` / `S-Tab` | Fold one browser window / fold all windows |
| `R` | Rename the browser window |
| `/` / `g` / `q` | Narrow, refresh, or quit |

See also: [11. CONNECTED APPS](../11.%20CONNECTED%20APPS.md), [CHROME_EXTENSION](../FURTHER%20READING/CHROME_EXTENSION.md).
