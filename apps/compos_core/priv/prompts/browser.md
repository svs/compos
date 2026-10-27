## Browser

Check the user's real page, not a mock. `(dom-measure SELECTOR [LIMIT])` gives the size, position and visibility of the matching elements in the editor tab. `(dom-eval JS)` runs JS in the editor tab.

## Reading a page

`(browse URL)` reads a page as text into its own buffer, `*browse:host/path*`, and gives the buffer name. From an agent it shows nothing.

- The fetch runs in the background, so the buffer is empty at first. Read it with `(buffer-text NAME)` on a later call, not in the same call. A page with too little text stays empty.
- `(buffer-local NAME 'browse-html)` gives the page source that the buffer holds.
- Use `(browse-other-window URL)` only when the user asks to see the page.
- For the raw body, use `(http-text URL)`. For status, headers and body, use `(http-get URL [OPTS])`.

## Site parsers

A site parser is an XSLT sheet, `~/.compos/packages/web/parsers/HOST.xsl`. `browse` runs it on the page before it makes the text, and it removes the site furniture (menus, footers, ads).

- If `browse-learn-parsers` is on, the first read of a new host learns a parser in the background, one time for each host.
- In a `*browse:*` buffer, the user runs `M-x browse-learn-parser` to learn the parser of that host again. The new parser replaces the old file.

To learn or fix a parser yourself:

1. `(xslt-discover HTML)` gives the page structure as rows: path, depth, tag, id, class, role, chars, links, sample.
2. `(xslt-stylesheet "//body" DROPS)` makes a sheet. DROPS is a list of `(PATTERN NOTE)`. `(xslt-pattern ROW)` gives the pattern for a row.
3. `(xslt-save! URL SHEET)` writes the sheet as the parser for the host and gives its path.
4. `(xslt-apply PATH HTML)` runs the sheet on HTML. Read the result: the content must stay and the furniture must go. If not, change DROPS and go back to step 2.

`(xslt-learn URL HTML)` does steps 1 and 2 in one pass and asks a model which rows are furniture. It is slow, so run it in a task.

## The user's Chrome

These calls use the user's own Chrome, so a page behind a login reads as the user sees it. Check `(browser-connected?)` first.

- `(browser-snapshot URL K)` loads URL in a background tab and gives K the html after the scripts run.
- `(tab-list K)` gives every open tab as id, title, url and active.
- `(tab-read TAB K)` gives the url, title and visible text of one tab.
- `(tab-eval TAB CODE K)` runs JS in a tab.

These calls are async: K runs after your eval returns, so let K write into a buffer and read that buffer on a later call.

`(tab-open URL)`, `(tab-activate TAB)`, `(tab-click TAB X Y)`, `(tab-type TAB TEXT)` and `(tab-close TAB)` change what the user sees. Ask before you use them.
