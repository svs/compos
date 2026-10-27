# Testing

The kernel's Scheme tests live in `priv/tests`; a package's tests live beside
it as `scheme/packages/NAME-test.scm`. Run one file at a time while working:

    SCHEME_TESTS=name mix test apps/compos_core/test/compos/scheme_suite_test.exs
    SCHEME_TESTS=name mix test --include packages apps/compos_core/test/compos/package_suite_test.exs

`SCHEME_TESTS` matches the file name; a comma separates several. The tests
that go red by order only are listed in KNOWN-FAILURES.md.

## Fixtures

Tests share one live editor, so a test that changes shared state puts it
back, also when a check raises half way. `scheme/packages/test.scm` has
the fixtures; `test-test.scm` beside it proves each one undoes its work on
the happy path and after an error. Use them instead of a hand-rolled
`(let ((old X)) (set! X ...) ... (set! X old))`.

| Fixture | Use |
| --- | --- |
| `(with-stub 'NAME VALUE THUNK)` | a global, by quoted name: a seam function, a table, a flag. A name with no binding is unbound again after. |
| `(with-stubs (list (list 'A 1) (list 'B 2)) THUNK)` | several globals at once |
| `(with-custom 'NAME VALUE THUNK)` | a customize variable; the setter runs on the way in and on the way out |
| `(with-customs (list ...) THUNK)` | several settings at once |
| `(with-fresh-group NAME FN)` | a group record; a stale record of that name goes first, FN gets the id, the record goes after. A dissolve inside FN is fine. |
| `(with-frame FN)` | a frame of the test's own, selected while FN runs with its id; the old frame is selected again after and the new one is deleted |

A stub that must capture the original calls it through a local:

    (let ((orig buffer-set-read-only!))
      (with-stub 'buffer-set-read-only!
        (lambda (buf value) (count!) (orig buf value))
        (lambda () (list-refresh! buf))))

A test that changes the value again inside the thunk may `set!` it; the
fixture still puts the original back.

Files converted so far: anchor, anon, apropos, chat-name, chat-scheme,
chat-unstick, chat-view, decide, display-buffer, do, doom, fast-code,
file-group-context, group-membership, group-prompt, keys, layouts,
list-redraw-read-only, llm-config, lsp, messages, modeline, needle,
paredit, perf, permission, popper, profile, prompt,
recording, repl, sentry, setup, skills, transient, window-config. The
rest still hand-roll their setup and can be converted the same way.
