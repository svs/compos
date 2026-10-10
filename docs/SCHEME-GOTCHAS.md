# Scheme gotchas

Builtin behaviours in the compos Scheme that a reader would guess wrong. Each one cost a debugging round trip. Probe an unfamiliar builtin with a one-line `eval-scheme` instead of assuming Scheme-standard semantics.

## Values and truth

- `'()` is truthy. `(or (buffer-local b 'k) (compute))` never recomputes once the local holds an empty list. Test with `pair?`, not with truthiness.
- `(string->number "x")` returns the atom `:error`, not `#f`. Test the result with `number?`.
- `(plist-get #f KEY)` raises `cdr: no function clause`. JSON null parses to `#f`, so code that walks parsed JSON needs a guarded getter.
- `(cons 1 2)` raises "no function clause matching". `cons` wants a list tail; use a two-element list for a pair.

## JSON

- `(json-encode '())` is `"[]"`. An empty plist and an empty list are the same value, so there is no empty object; omit the key instead.
- `json-parse` sorts object keys. Insertion order is not kept.

## Strings

- `string-index` counts bytes; `substring` and `string-length` count characters. Mixing them corrupts a scan over text with a multibyte glyph. Scan with a char loop over `substring`.
- `substring` needs 3 arguments.
- Regex replace-all is `(re-replace-all PAT S REPL)`.

## Procedures and lists

- Dotted formals do not exist. `(define (f a . rest) ...)` parses `.` and `rest` as two positional parameters. Pass an explicit list.
- `map`, `for-each`, and `fold` take one list; `fold` is `(F ACC X)`. Zip the lists first.
- These do not exist: `even?`, `list?`, `catch`, `random`, `cadddr`, `list->string`, `string->list`, `char-alphabetic?`, `revert-buffer!`. `when` and `unless` are syntax and are not `boundp`. Use `(cadr (cddr r))` for the fourth element. `(ignore-errors (lambda () ...))` returns `#f` on a raise.

## Buffers and the daemon

- `buffer-save!` takes no arguments. Run it inside `with-current-buffer`.
- Replace a whole buffer with `(buffer-delete-range! BUF 0 (buffer-size BUF))` then `buffer-append!`.
- `buffer-create` and `switch-to-buffer!` on a dormant name make a fresh empty buffer. Wake a dormant buffer through a via-routed call (`fold-get`, `buffer-set-local!`) or the switcher preview.
- An `eval-scheme` call that raises rolls back the whole form; side effects earlier in the `begin` do not survive.
- `eval-scheme` fails with a bare `parse error` on a payload past roughly 5 KB. Build a long insert by appending chunks to a scratch buffer, then insert `(buffer-text ...)` in one call.
- `reload-file` swallows the file's return value. Probe results through a global or a follow-up eval.
- A `set!` on a defcustom global over the RPC socket may not reach the global that a later UI callback reads. `customize-save!` sticks.
- A test that waits on a debounced callback deadlocks, because the test holds the lane. Call the callback directly.
