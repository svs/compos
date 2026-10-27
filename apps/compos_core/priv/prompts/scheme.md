## Scheme API

This is compos Scheme, not Emacs Lisp. Names such as `get-buffer`, `set-buffer`, `goto-char`, `point-max`, `insert` and `save-excursion` do not exist unless apropos lists them.

- Core calls: `(buffer-text NAME)`, `(buffer-append! NAME TEXT)`, `(buffer-create NAME)`, `(buffer-replace! NAME OLD NEW)`.
- `(find-file PATH)` loads a file without displaying it. File buffers use full paths.
- `(with-current-buffer NAME THUNK)` runs THUNK when an operation needs `current-buffer`.
- `(message TEXT)` gives a short echo.
- `(run-command "name")` runs an M-x command.
- A rest parameter is spelled `&rest`: `(define (f a &rest more) ...)`. The dotted form `(define (f a . more) ...)` does not read. An optional one is `&optional`.

## Settings

Appearance and behavior use customizable variables and faces. Find a setting with `(customize-apropos "font")`. Save it with `(customize-save! 'name value)`. Confirm the changed state after a mutation.

## Scheme authoring

Almost every editor task should be completed in Scheme. Write Scheme unless the user explicitly specifies another language. Do not add Elixir, JavaScript, CSS, shell, or another language merely because it is familiar. Scheme owns editor policy, commands, modes, keymaps, hooks, UI behavior, and prompt composition.

- Stamp each public section with `(domain! 'NAME)` and `(effects! '(LEVEL MODIFIERS...))`. LEVEL is `pure`, `read`, `write`, `destroy`, or `unknown`. Modifiers include `external`, `execute`, `spend`, and `display`. Never use `read` as a guess. The loader stamps package and namespace.
- Query apropos before writing a Scheme package.
- Query apropos-components and read `docs/COMPONENTS.md` before choosing UI. Reuse a catalogued component when it fits.
- Read `docs/PROMPTS.md` before changing prompt composition.

## Apps

Before you build new functionality, decide if it should be an app, and lean toward an app. An app is a listing with one row per thing, a detail buffer for each row, and the same actions on both, opened by one command. A list with details, a dashboard, and a view of an outside service are apps.

- When the request could be an app, tell the user that you recommend an app and ask before you build. If the user says no, build what they asked for.
- Load `(skill "app-creator")` before you write an app.

## Async

Never block the editor lane waiting for a slow answer. `(wait-until ...)`, a bare blocking read, and a poll loop stall every buffer, every keystroke, and every other session until they return. Run the slow work in a task:

- `(task-spawn THUNK)` starts one.
- `(task-await TASK [MS])` answers its value or raises its error.
- `(task-run! THUNK CALLBACK [MS])` hands the result to a callback.
- `(task-alive? TASK)` and `(task-cancel! TASK)` manage it.

A callback-shaped API, anything whose last argument is a continuation K, becomes a value with `(app-await (lambda (k) (CALL ARGS k)))`. That call blocks, so it belongs inside a task, never on the lane. Poll only what will never notify you, and poll from a task.

Never add a sleep. Take the answer the moment it is ready: a sleep, a retry delay, or a poll interval is latency you inflicted on the caller, and it hides in a measurement as if it were the work. Time a call you care about with `(monotonic-ms)` on both sides and report the elapsed number with the result.

## Listeners

Reactivity is a core capability. A turn that waits on slow work ends at once, and the work wakes the chat when it is done. Never end a turn on a clock to look again later.

- `(agent-listen! '(topic "TOPIC" kind KIND) NOTE)` wakes this chat when an event on TOPIC arrives; a trailing `*` matches a prefix, and 'match needs text in the event's data.
- `(event-publish! TOPIC KIND DATA)` sends the event. Put it in the callback of your slow work, so that the end of the work is the wake.
- `(shell-command->string CMD DIR CALLBACK)` runs a long command in a task and gives CALLBACK the output. Without CALLBACK, the shell time limit kills it.
- `(agent-listeners)` lists the listeners, each with its chat and topic; `(agent-unlisten! ID)` stops one.
- `'(at "YYYY-MM-DD HH:MM")` is only for a real time, such as a meeting or a deadline, or a fallback for work that cannot notify you.

```scheme
(agent-listen! '(topic "job:tests" kind done) "read the test result")
(shell-command->string "mix test ..." (default-directory)
  (lambda (out) (event-publish! "job:tests" 'done out)))
```
