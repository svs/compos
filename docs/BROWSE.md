# Browse

`browse` is compos's readable-web mode. It fetches a URL, extracts either the article or the complete document, converts the result to Markdown, and presents it in a read-only buffer with browser-like navigation.

The implementation lives primarily in `apps/compos_core/priv/packages/web.scm`. Markdown preview behavior lives in `apps/compos_core/priv/packages/preview.scm` and `apps/compos_core/priv/packages/markdown-mode.scm`.
## Pipeline at a glance

```text
URL
  -> browse tab and session-cache lookup
  -> browser fetch
  -> curl fallback with ETag revalidation
  -> raw HTML
  -> calm extraction or full-document reading
  -> Pandoc GFM Markdown
  -> canonical Markdown in the browse buffer
  -> preview-mode renders that Markdown in the same tab
```

The fetch and cleanup pipeline produces Markdown. That Markdown is both the buffer source and the session-cache value. `preview-mode` is a view over those same bytes; toggling preview never rewrites the page.
## Opening a page and choosing a tab

`(browse URL)` normalizes its argument:

- A string containing `://` is already a URL.
- A host-like string such as `example.com/path` gains `https://`.
- Anything else becomes a query using `browse-search-url`.

From outside `browse-mode`, a URL gets its own browse tab, and opening the same URL returns to that tab. From inside a browse tab, a URL navigates the tab in place.

The buffer process keeps a stable identity during in-place navigation. Its visible `modeline-name` is recomputed from the URL, so the title follows the page. Browse tabs belong to the `browse` group, and `s` opens a switcher restricted to that group.

## Fetching HTML

The HTML pipeline tries the editor's browser fetch first. If that returns nothing, it falls back to `curl`.

The curl fallback follows redirects, has a 20-second timeout, and stores one ETag per URL under `$COMPOS_HOME/web-etags`. A revalidation sends the saved ETag. An unchanged response has no body, so the in-memory page remains authoritative.

A hard refresh adds a private cache-busting query parameter to the request without changing the canonical `browse-url`.

Some sites return only a JavaScript shell. If extraction finds no useful document, browse retries once through a rendered browser snapshot. A site may request that rendered fetch immediately through the site registry.

## Calm and full readings

Every page has a requested reading:

- **calm** extracts the main article;
- **full** keeps the complete document.

The default comes from `browse-reading`. A tab may override it with `browse-want`. `R` toggles the requested reading.

### Calm reading

For an ordinary site, calm mode runs `readable --base URL HTML_FILE`, then pipes the selected HTML through Pandoc. `readable` removes navigation, sidebars, cookie chrome, recommendations, and other material outside the main article. The base URL lets relative links survive extraction.

A registered site can replace `readable` with an XSLT stylesheet under `web/parsers`. The current registry is:

| Site | Parser | Render first? |
| --- | --- | --- |
| `substack.com` | `substack.xsl` | yes |
| `html.duckduckgo.com` | `duckduckgo.xsl` | no |
| `mukeshbishnoi.com` | `mukeshbishnoi.xsl` | no |
| `www.mukeshbishnoi.com` | `mukeshbishnoi.xsl` | no |

A transform-only parser should be registered directly in `*web--sites*`. Rendering should be enabled only when a normal fetch produces a script shell.

### Full reading

Full mode sends the complete HTML file directly to Pandoc, so it keeps site navigation, footers, repeated links, logos, and other furniture that calm mode removes.

Old pages sometimes use nested tables for layout. Pandoc can reduce such a page to the literal text `[TABLE]`. When that happens, browse strips the table-family tags and converts the flattened HTML again.

### Thin-result fallback

A reading shorter than the configured minimum is considered empty. If calm extraction is thin, browse retries the same HTML as full. This matters for index and search pages that are mostly links. If full is also thin, browse treats the document as unusable and may retry through a rendered snapshot.

## HTML to Markdown

Pandoc emits GitHub-Flavored Markdown with no hard wrapping:

```text
pandoc --wrap=none -f html-native_divs-native_spans -t gfm-raw_html
```

One source line per paragraph leaves wrapping to the editor window.
## Markdown source and preview rendering

Pandoc's GitHub-Flavored Markdown is inserted unchanged into the read-only browse buffer. `web--markdown-links` indexes link-label positions in that source for keyboard commands such as `TAB`, `n/p`, and `RET`.

A generated browse buffer has no `.md` filename, so `browse-mode` declares:

```scheme
(buffer-local BUF 'preview-renderer) ; => "markdown"
```

New browse tabs enable the real `preview-mode` minor mode by default. It sets:

```scheme
(buffer-local BUF 'render-mode) ; => "markdown"
```

The existing Markdown renderer owns headings, lists, block quotes, emphasis, tables, links, and images. Browse still applies its page-specific metadata and article-separator overlays, restores point, updates the title and modeline, and records the visit.

`C-c C-v` disables preview to reveal the unchanged Markdown source. Pressing it again renders the same source in the same tab.
## Images

Images remain ordinary Markdown image nodes in the buffer:

```markdown
![Alt text](https://example.test/image.png)
```

The shared Markdown preview renderer turns them into images. Browse no longer converts image syntax into special text ranges or maintains a second image renderer.

Calm mode may contain fewer images because article extraction removes logos, icons, navigation artwork, and unrelated media. Full mode retains the complete document, including site furniture. If the extracted Markdown contains no image node, preview has nothing to display.
## Caching and page lifetime

Browse uses several caches:

- ETag files survive restarts and make HTTP revalidation cheap.
- `browse-pages` is a per-tab list of `(URL READING MARKDOWN TIME)`.
- `browse-html` holds raw HTML so `R` can change readings without fetching.
- The generic buffer cache applies `*web-cache-ttl*`, currently 600 seconds.

A tab retains at most 20 page entries. Returning to a cached URL can render its Markdown immediately. Revalidation that returns no body, or a failed request, keeps the held copy instead of blanking the buffer.

`browse-pages` and `browse-html` are excluded from desktop persistence because they are large and derived from the URL. A restored browse buffer may keep readable text, URL, history, and point, but stale content is refetched.

## Navigation, history, and point

The displayed page uses the buffer's ordinary editor point. Because several URLs navigate through one buffer, back and forward history entries store:

```text
(URL POINT)
```

The rules are:

- a fresh destination starts at point 0 and resets the window to the top;
- leaving a page records its current point;
- back and forward restore the saved point;
- a same-page refetch preserves the current point;
- legacy entries containing only a URL open at point 0.

`buffer-windows-follow-point!` clears a window's manual scroll pin after a render. Without it, a window scrolled down on the old page could keep its pixel offset over the new page even though point is 0.

Relative link targets are resolved against the current page URL when followed.

## Visit history, bookmarks, and source

Successful renders enter persistent web history with URL, title, and time. `H` opens the history. Bookmarks use the ordinary bookmark system and record URL and point.

`v` opens the held raw HTML in a read-only `html-mode` buffer. A page restored only from cached Markdown may have no raw HTML; refetching restores it.
## Commands

| Key | Action |
| --- | --- |
| `RET` | Follow the link at point |
| `s-RET` | Open the link in its own browse tab |
| `M-RET` | Peek the link in another window |
| `TAB`, `n`, `p` | Move among links |
| `l`, `M-Left` | Back |
| `M-Right` | Forward |
| `u` | Parent URL |
| `t` | Site root |
| `g` | Refetch this page or enter another destination |
| `r` | Hard refresh |
| `R` | Toggle calm/full reading |
| `o` | Open externally |
| `w` | Copy the link at point, otherwise the page URL |
| `v` | Show held raw HTML |
| `d` | Download the link at point, otherwise the page |
| `H` | Visit history |
| `b`, `B` | Set or list bookmarks |
| `s` | List browse tabs |
| `M-n`, `M-p` | Cycle browse tabs |
| `C-c C-v` | Toggle Markdown source/preview in this tab |
| `q` | Quit the window |

## Preview integration

Browse uses the same `preview-mode` implementation as generated help pages and Markdown documents.

There are two web-specific integration rules:

- rendered HTTP and relative links route back through `browse`;
- relative targets resolve against the buffer's `browse-url`, not as local document paths.

Mouse navigation from the rendered document and keyboard navigation from the Markdown source therefore reach the same in-place browse history. Fresh destinations start at point 0, while back and forward restore the source point saved for that URL.

The source remains authoritative. Preview state changes presentation only; caching, calm/full rereading, raw HTML source, visit history, bookmarks, titles, and point restoration continue to belong to `browse-mode`.
## Tests

Browse behavior is covered by:

- `apps/compos_core/priv/tests/web-browse-test.scm`;
- `apps/compos_core/test/compos/web_browse_test.exs`;
- `apps/compos_core/test/compos/window_follow_test.exs`;
- Markdown and image-overlay tests under `apps/compos_core/priv/tests` and `apps/compos_ui/test`.
