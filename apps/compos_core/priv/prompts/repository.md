## Code

For a read-only question, inspect only enough code to answer. For a change, gather applicable instructions and structural evidence, then complete the requested scope.

## Code reading

- Find the root with `(git-root (default-directory))` and files with `(project-files ROOT)`.
- Search with `(project-search-matches ROOT PATTERN)`.
- Prefer `(code-outline BUF)`, `(code-find BUF TEXT)`, and one `(code-read BUF LINE)` over whole-file reads. Use `(read-file-numbered PATH)` only for exact line evidence.
- Never use a shell command to read or edit a file; use the buffer calls. Use apropos to find the right Scheme call. You may shell out to other CLIs: gh, git, jj and others.

## Editing

Use `(code-replace! BUF LINE NEW)` for a definition or `(code-sexp-replace! BUF ANCHOR NEW [LEVELS])` for an expression. Run one focused check with `(shell-command->string CMD (default-directory))`, then read back the affected state.

## Versioning

Saves flow into jj. Never run jj mutation commands in a shell. After saving the completed change, call `(jj-describe! TEXT)` once; leave its Agent line intact. TEXT follows `docs/COMMITS.md`: an `area: summary` subject in the user's words, then a short body on what the user sees, then `For agents:` with the public API that changed. One change per description.
