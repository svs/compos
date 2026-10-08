---
name: skill-creator
description: Write a new compos skill, or revise one: the frontmatter, the prose, and a scheme run block for the steps that are fixed. Load before you create or change a SKILL.md.
---

# Write a skill

A skill is a folder with one `SKILL.md`. Agents read the prose. `skill-run`
runs the code in it, when it has code. Write the prose first, then add code
only for the steps that are always the same.

## Where it goes

- `priv/skills/NAME/` for a skill that ships with the editor.
- `~/.compos/skills/NAME/` for the user's own skill.
- `(skills-group-dir G)` for a skill that only one group sees.

After you write it, call `(skills-scan!)`. Then `(skill "NAME")` must
give the body.

## Frontmatter

```
---
name: NAME
description: What the skill does. Load when ...
---
```

The description is the only line an agent sees before it loads the skill.
Say what the skill does and when to load it, in one or two sentences.

## Prose

Write for an agent that knows the editor but not this task. Give each step
the exact call it uses, in backticks. Say what to check before and after an
action. Put each rule that protects the user in the prose, such as "ask
before you send". The code must follow the same rules.

Find every call with `(apropos "words")` and read its source with
`(describe-function 'NAME)` before you name it. Do not guess names.

## Code

Add code when the steps are fixed calls: read a record, fetch a thread,
send, log, close. Leave a step to the prose when it has no fixed shape,
such as "find the thread" for a source you do not know.

The code is one fenced block with the info string `scheme run`. It holds
one form, `(lambda (args) ...)`. Other `scheme` blocks in the file are
examples, and nothing runs them.

- ARGS is the text the caller gave, maybe empty.
- Answer a string: what the skill did, in one or two sentences.
- Answer the symbol `'prose` for a case the code does not cover. Then
  `skill-run` gives the same call to an agent with the prose.
- The code runs in a task. It may block on the calls below, but it never
  sleeps, polls, shows a buffer or moves focus.

Where a step needs judgment, the code asks a model:

- `(skill-ask PROMPT [ABOUT])` gives the fast model's answer as text. Use it
  to write: a reply, a summary, the result line of a todo.
- `(skill-decide STATE QUESTIONS)` gives typed answers. Use it to choose a
  branch. Make each question with `(decide-noul INSTRUCTIONS)` for yes or
  no, or `(decide-choice INSTRUCTIONS CRITERIA)` to pick one, where CRITERIA
  is a plist of option and description. Read an answer from
  `(plist-get RESULT 'answers)`: a row is `(KEY ANSWER)`, and ANSWER holds
  `noul`, a probability from 0 to 1, or `choice`, the option.

An example. In a skill its fence says `scheme run`; here it is only an
example, so it does not:

```scheme
(lambda (args)
  (let* ((todo (todo-get args))
         (source (plist-get todo 'source)))
    (if (not (and source (string-prefix? "whatsapp:" source)))
        'prose
        (let* ((r (skill-decide (plist-get todo 'notes)
                                (list 'replied (decide-noul "Did we already reply?"))))
               (row (assq 'replied (plist-get r 'answers))))
          (if (> (plist-get (cadr row) 'noul) 0.5)
              (begin (todo-done args "Already answered." "skill:todos")
                     "Closed: we already replied.")
              'prose)))))
```

## Check it

1. `(skill-check "NAME")` must give `()`. It names a block that does not
   read, a block that is not one lambda, and every call that nothing
   defines.
2. `(skill-state "NAME")` must give `code`.
3. Run it once on a real input with
   `(skill-run "NAME" ARGS (lambda (ok? v) ...))` and read the result.
   Do this only when the skill's actions are safe to do now. If they are
   not, show the code to the user and stop.
