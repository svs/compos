---
name: orchestrate
description: Run a large change as a tree of todos, each in its own chat, from one orchestrator chat. Use when a task splits into parts that can be worked in parallel. Do not use for a change one chat can do in one sitting.
---

# Orchestrate a todo tree

## When to fan out

Fan out when the work has three or more parts that touch different files.
Keep it in one chat when the parts share files, or when the whole change
is smaller than a sitting. Every chat costs turns, and every merge costs
your attention.

## Split by files

1. Make one root todo for the whole change. Put the plan in its notes.
2. File one sub-todo per part with `(todo-create TITLE (list 'parent ROOT
   'state "todo" 'group GROUP 'depends (list ID ...)))`.
3. Give each part its own files. Two parts that edit one file must not run
   at the same time: make the second depend on the first.
4. Write each part's notes as its whole brief: the goal, the files, and
   what "done" means. The chat sees only its todo.
5. Add a last todo that depends on all the others, to check the whole.

A todo starts when every depend is in review or done. Leave a part in
inbox when a human must triage it first.

## Run it

`(orchestrate! ROOT)` makes this chat the orchestrator. Scheme, not you,
does the rest: at each child turn end it reads the tree and starts every
ready todo in a titled chat, linked to you with notify, with the standard
todo brief. The answer gives what started and the tree.

You are woken only for judgment, and only one time for each occasion:

- a todo in doing whose chat is gone: start it again with
  `(todo-assign-chat! ID GROUP)`, or cancel it;
- a todo in review whose log says tests fail: read it with `(todo-get
  ID)`, then send its chat back with `(agent-continue! CHAT TEXT)`, or fix it;
- a todo that depends on a cancelled one: change its depends or cancel it;
- every todo in review or done: report.

After you change the tree, `(orchestrate-step!)` starts what is ready
now. `(orchestrate-status)` gives the tree. Do not poll: the next child
turn end wakes the step. Before you end a turn while children run, set a
fallback wake-up with `(agent-listen! '(at "YYYY-MM-DD HH:MM") NOTE)`.

The state lives on the chat, so a restart keeps the run. The user sees
the tree in the todo list and the chats in `M-x subagents`.

## Report

When all are in review or done, report to the user in one short list:
each todo, its state, and one line of its result. Name the failures and
the open questions first. Then `(orchestrate-stop!)`, and move the root
to review. Never approve the children for the user.
