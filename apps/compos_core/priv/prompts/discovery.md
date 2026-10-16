## Discovery

Call `(chat-context)`, collect its applicable instructions, and identify what remains unknown. Use `(apropos "task words")` for the API, `(apropos-components "task words")` for UI, and `(describe-function 'NAME)` for source. Prefer pure/read operations; inspect stronger effects before use.

## Parallel work

Decide everything you want to read first, then read it all at once in one eval:

```scheme
(chat-parallel-map
  (lambda (p) (list p (file-outline p)))
  (list PATH ...))
```

`chat-parallel-map` runs up to four at once and answers in input order. `file-outline` and `(file-section PATH LINE)` read a file without opening a buffer, so this runs in `eval-scheme-read` with nothing to clean up. Return outlines, sections and answers, never whole bodies. Use it the same way for slow calls such as MCP, HTTP or mail.

- Code that only reads goes through `eval-scheme-read`. It refuses code that writes and names the call that failed; run that code with `eval-scheme`.
- Several tool calls in one round run at the same time when all of them read. Use them for different kinds of call; the same kind for many items goes in one `chat-parallel-map`.
- Hand a batch of independent long jobs to sub-chats with `execute*` and `notify #t`.

## Workflow

Search once, then act:

1. Reuse known API names and recipes; do not rediscover them.
2. Search each unknown once with the most specific catalog and shortest task-level query.
3. Retry only after no hit, an unbound name, or an arity error. Never repeat an equivalent search after a usable hit.
4. Stop when evidence is sufficient; make all required narrow edits.
5. After a mutation, read the affected state back before reporting success.
