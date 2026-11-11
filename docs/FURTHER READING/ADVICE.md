# Advice

Advice attaches behavior to a named function. The function does not need a hook or knowledge of its advisers.
Each registration has a name. You can inspect it, disable it, enable it, or remove it.
Scheme owns the registry and execution policy in `scheme/packages/advice.scm`.
The stock loader (`priv/init.scm`) loads this package early, before most bundled packages.

## API

```scheme
(advice-add! 'target 'after 'my-advice 'my-handler)
(advice-disable! 'target 'my-advice)
(advice-enable! 'target 'my-advice)
(advice-enabled? 'target 'my-advice) ; #t or #f
(advice-list 'target)              ; includes disabled advice
(advice-list)                      ; every registration
(advice-remove! 'target 'my-advice)
```

`TARGET` names an existing global function. `NAME` is a symbol unique within that target.
`FUNCTION` is a function symbol or a closure. Prefer symbols: each invocation resolves the current handler definition.
`WHERE` is `before`, `after`, or `around`.
Special forms such as `if` are not functions and cannot receive advice.
Command registry names are separate from function bindings; advise the function a command calls.

A new registration starts enabled. Registering the same target and name replaces the handler and position without adding another row.
Replacement preserves registration order and the enabled state. Reloading a package cannot silently enable disabled advice.
`advice-add!` returns the registration name. Removal returns `#t`, or `#f` when the registration is absent.
Enabling returns `#t`; disabling returns `#f`. Both signal an error if the registration is absent.
`advice-enabled?` returns `#f` for absent advice.

Each inspection row is a plist:

```scheme
(target target name my-advice where after function my-handler enabled #t)
```

## Calling conventions

Before and after handlers receive the target's arguments. Their return values are ignored.
After advice runs only when the target returns normally. The caller receives the target's result.
An error in before advice prevents the target from running. An error in after advice propagates; it cannot undo the target's effects.

```scheme
(define (log-open buffer)
  (message (string-append "Opened " buffer)))

;; Example target supplied by the application.
(advice-add! 'open-buffer! 'after 'log-open 'log-open)
```

Around handlers receive `NEXT`, followed by the arguments. Calling `NEXT` continues the chain.
An around handler can change arguments, change the result, call `NEXT` several times, or skip it.
Use `apply` when forwarding a variable number of arguments.

```scheme
(define (trace-open next &rest args)
  (message "Opening buffer")
  (let ((result (apply next args)))
    (message "Open complete")
    result))

(advice-add! 'open-buffer! 'around 'trace-open 'trace-open)
```

Before handlers run in registration order, then the target, then after handlers in registration order.
Around handlers surround this sequence. The earliest registered around handler is outermost.
Skipping `NEXT` also skips the inner before and after handlers.
Arguments supplied to `NEXT` reach the target and its before and after handlers.
Each invocation snapshots its enabled registrations and resolves its handlers before running the chain.
A change during the invocation takes effect on the next invocation. Recursive calls through the target name also run advice.

## Example: groups

Group membership belongs in after advice. Opening supplies the display behavior; groups add their membership policy after it succeeds.
The following example assumes an application function `open-buffer!` whose first argument is the opened buffer name.
It illustrates the contract; this change does not introduce `open-buffer!` or change existing group behavior.

```scheme
(define (group-join-after-open buffer &rest options)
  (let ((group (frame-group)))
    (when group
      (buffer-add-group! buffer group))))

(advice-add! 'open-buffer! 'after 'group-membership 'group-join-after-open)

;; Keep the registration, but suspend automatic membership.
(advice-disable! 'open-buffer! 'group-membership)
(advice-enable! 'open-buffer! 'group-membership)
```

## Lifetime and function identity

Advice follows the global binding across `define`, `set!`, `set-symbol-value!`, and source reload.
Redefining a named handler also takes effect on the next invocation.
Removing the last advice restores the latest unwrapped target definition.
A lexical function with the same name has its own binding and receives no global advice.

Advice wraps the binding, not every copy of a function value.
An alias captured before registration still calls the original function.
An alias captured afterward carries a wrapper and consults the registry, but retains the target definition captured with that value.
Direct calls and `apply` through the current binding use the current definition.

Registrations and toggles survive source reload, including reload of the advice package itself.
They are runtime state, not desktop state. On restart, package and user init files recreate registrations in load order.
Put a persistent disable call after the corresponding registration in the user init file.
Registry edits use a Scheme lock; they must run outside concurrent target redefinition.
As elsewhere in Scheme, another execution lane can retain cached bindings until its evaluation ends.
Avoid advising the advice implementation or its own dispatch dependencies; that can recurse into advice dispatch.

## Runtime mechanism

`function-interpose!` is the internal mechanism used by advice. It installs one wrapper on a global callable binding.
The wrapper receives the original callable and the argument list. Passing `#f` removes the wrapper.
Applications should use the advice API; they must not replace this internal wrapper directly.

Elixir preserves the wrapper when a binding changes and invokes it like any other Scheme callable.
The callable remains compatible with `procedure?`, `apply`, closure publication, garbage collection, and primitive refresh.
Scheme supplies all registration, ordering, and toggle behavior.

## Tests

`scheme/packages/advice-test.scm` checks the public policy through the real Scheme session.
`apps/compos_core/test/compos/advice_test.exs` runs those tests and checks reload behavior.
The interpreter tests check binding replacement, lexical shadowing, closure collection, and primitive refresh.
