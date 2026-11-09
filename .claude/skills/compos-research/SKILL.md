---
name: compos-research
description: Investigation discipline for debugging or exploring compos — search each unknown once with the most specific query, stop as soon as there is enough evidence to act, and don't expand a read-only question into a repository change. Use before an open-ended debugging task, or when tempted to keep re-checking something already confirmed.
---

# Investigating compos

## Scope first

If the request does not require a code change, do not inspect or modify the
repository beyond what answering it takes, and do not load `code-change`.
A question gets an answer; a bug report gets a diagnosis. Neither
automatically earns an edit.

## Search once, then act

1. Reuse a name you already confirmed this session — do not
   re-derive it.
2. Search each unknown once, with the most specific query the catalog or
   grep supports.
3. Retry only after a genuine miss: no result, an unbound name, an arity
   error, a file that turned out to be the wrong one. A hit that already
   answers the question does not get re-verified from a different angle
   "to be sure" — that is cost with no new information.
4. Stop when the evidence explains the observed behavior. A second,
   third, and fourth isolated reproduction of a mechanism already proven
   correct does not make it more correct.

## Live state moves out from under you

The user's daemon is not a fixture — it is a real session they keep
working in while you investigate. A frame, window, or buffer you read a
few commands ago can be gone by the time you act on it, because the user
kept typing. Re-check current state immediately before acting on it rather
than trusting an earlier snapshot, and consider that a symptom you set out
to reproduce may have already resolved itself through the user's own next
action — don't chase a moved target past the point of diminishing return.

## This daemon holds real, sensitive state

`bin/compos tabs` returns the user's actual open browser tabs verbatim —
titles and URLs from their real mail, calendar, recruiting system, and
anything else open, occasionally including a live token embedded in a
URL. Only reach for it when the task genuinely needs to know what tab is
open, never as a quick way to "see what's going on." Treat anything it
returns as sensitive: don't restate it, don't quote it back at length, and
don't forward it anywhere.

The same caution applies to `bin/compos eval` calls that read a real
`*notmuch*`, chat, or other content buffer — reading state is fine;
running a command that mutates the user's actual mail, files, or window
layout to "just check" is not, unless it is reversible and it is the exact
action already in question.

## After a mutation, verify

Read the affected state back before reporting success. This is the
`code-change` skill's completion gate too — a fix or a probe is not
confirmed until you have looked at the result, not the intention.

## Related

- `compos-reading` — how to read the source and the live catalog without
  dumping whole files.
- `compos-debug` — the `bin/compos` toolkit this skill assumes.
- `code-change` — the gate for turning a confirmed diagnosis into a
  durable repository change.
