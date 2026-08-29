# Compos homepage brief

## Assignment

Design and build a distinctive, production-quality homepage for **Compos**, the operating system for knowledge work: a place that grows and shrinks around the work at hand through ephemeral, task-shaped applications.

The page should make Compos feel like a new computing environment, not another AI code editor and not an Emacs remake. It inherits the most important idea in Emacs—that every tool can share one inspectable, programmable world—and extends it to modern work, integrations, graphical applications, concurrency, and agents.

## Product truth

Compos is **the operating system for knowledge work**.

Its defining mechanism is **ephemeral apps over durable, observable state**.

When a task appears, the environment should be able to grow the application needed for it: a Sentry triage room, a calendar planner, an email workspace, a release console, or a custom interface over an MCP. When the task is over, the application may disappear. Its useful state does not.

- Apps are composed for the work at hand rather than installed forever.
- Buffers make their state durable, inspectable, searchable, and scriptable.
- Windows are temporary views over that shared state.
- Named commands give people and agents the same semantic action surface.
- Modes and hooks add contextual behavior.
- Scheme keeps editor policy live, inspectable, and redefinable.
- Elixir/OTP owns concurrency, processes, sockets, terminals, parsing, and model streams.
- Sentry, calendars, email, terminals, databases, and custom MCPs become native materials for applications.
- The browser renders application state; it does not own or conceal it.
- Agents act through the same buffers and commands as the person. They do not depend on scraping pixels or operating a parallel chat world.

Three governing sentences:

> **Apps are ephemeral. State is durable. Actions are semantic.**
>
> **Everything is observable through a buffer.**
>
> **Elixir supplies mechanism. Scheme decides policy.**

## Audience

People whose work spills across editors, browsers, terminals, dashboards, SaaS products, and agent conversations—especially programmers who understand why Emacs, Lisp machines, Smalltalk, REPLs, and Unix remain important. They want to assemble the right environment for a task without creating another permanent product or surrendering its state to an opaque interface. Assume technical literacy. Do not explain AI basics or use breathless productivity claims.

## Desired impression

Compos should feel:

- alive rather than automated;
- calm rather than corporate;
- intellectually serious without becoming austere;
- Indian in origin through the name and bird, without decorative pastiche;
- like an instrument someone can inhabit for years.

The Asian compos is a visual presence, not a cartoon mascot. The hidden reading **`ko.el`** may appear once as a quiet typographic Easter egg, but the product name is always **Compos**.

Do not rename the product **Ephemeral**. Ephemerality describes the lifecycle of its apps, not the identity of the system. Compos should feel like the living habitat in which those temporary forms appear.

## Hero

Use the supplied image at `/images/compos-hero.png`. Place copy in its clear left field; preserve the bird and technical branch on the right. The image must crop gracefully on narrow screens rather than sitting behind unreadable text.

Suggested copy:

**Eyebrow**  
COMPOS

**Headline**  
The operating system for knowledge work.

**Supporting copy**  
Build the app this moment needs. Compos turns your tools and live data into deeply integrated, task-shaped applications. Bring in Sentry, calendars, email, terminals, or custom MCPs; work with people and agents through shared commands and observable buffers; let the interface disappear when the work is done.

**Primary action**  
See how Compos works

**Secondary action**  
Read the architecture

Near the actions, include one compact thesis line rather than an inflated metric:

`ephemeral apps · durable state · one command surface`

Do not place text inside the image asset.

## Page narrative

### 1. Software shaped like the task

Start with the problem. Work arrives in temporary shapes, but conventional software arrives as permanent, isolated products. A production incident needs errors, deploys, code, owners, chat, and actions in one place. A hiring loop or trip or research question needs a different application. Today, people perform that integration manually across tabs.

Compos lets the environment form around the task, then recede. Show three concrete examples rather than generic feature cards:

- **Investigate an incident:** Sentry events, the relevant code, deploy history, owners, and remediation commands in one live workspace.
- **Plan a week:** calendars, email threads, tasks, and an agent-generated agenda sharing the same underlying state.
- **Build the missing tool:** compose a focused interface over a custom MCP, use it, retain its buffers and history, and discard the shell when it is no longer needed.

Caption the sequence:

`need → compose → work → remember → dissolve`

### 2. Everything becomes a buffer

This is the central product distinction, not an implementation footnote. In conventional applications, state is trapped behind a UI, remote API, or rendered HTML. In Compos, useful state enters the environment as a buffer: visible to the person, addressable by commands, and available to agents without screen scraping.

Use a visual mapping with real examples:

`Sentry issue → buffer`  
`calendar range → buffer`  
`email thread → buffer`  
`terminal process → buffer`  
`agent run → buffer`

The point is not that everything becomes plain text. A buffer may have a rich graphical view. The buffer is the durable, observable application object beneath that view.

### 3. The shared world

Lead with the main distinction: most AI tools place an agent beside an editor. Compos gives the person and the agent the same buffers, commands, modes, tools, and state.

Show a concise visual relationship:

`person ↔ commands ↔ buffers ↔ agents`

The relationship is reciprocal. Avoid a funnel or “AI magic” diagram.

### 4. Apps can be temporary because the substrate is durable

Explain the apparent paradox. Compos does not make work disposable. It separates the temporary interface from the durable substrate beneath it:

- **Ephemeral:** layouts, views, task-specific controls, agent teams, and combinations of tools.
- **Durable:** buffers, provenance, history, definitions, permissions, and the commands that changed state.

An app can vanish without taking the work with it. It can be reconstructed, remixed into another app, or inspected later.

### 5. Mechanism and policy

Make the architectural rule a strong editorial moment:

> Elixir supplies mechanism.  
> Scheme decides policy.

Use a two-column comparison:

- **Elixir / OTP:** ropes, tree-sitter, sockets, PTYs, schedulers, LLM transport, supervision.
- **Scheme:** commands, keymaps, modes, hooks, themes, chat, mail, org, dired, applications.

The columns should visibly interlock instead of looking like competing products.

This is where the Emacs and BEAM lineage may be named. It supports the proposition; it is not the opening proposition.

### 6. Everything is alive

Show the immediacy of extending the system with a small, authentic Scheme example:

```scheme
(define-command "insert-buffer-name"
  "Insert the name of this buffer"
  (lambda () (insert! (current-buffer))))

(global-set-key "C-c n" "insert-buffer-name")
```

Caption: **Evaluate it. The command exists. Use it from a key, a view, an agent, or another app.**

### 7. Capabilities

Use a restrained grid or editorial index—not floating SaaS cards—for:

- Task-shaped, ephemeral applications
- Durable buffers and workspace state
- Rich views over inspectable data
- Shared commands for people and agents
- Live Scheme-defined behavior
- Supervised concurrent processes and agents
- Native MCP and external-service integration
- Provenance-aware changes and history

Each item gets one factual sentence. Avoid invented features and future promises.

### 8. One core, many views

Illustrate the system as a small architectural stack. External systems feed typed buffers and semantic commands into the core; different clients render views over it:

`Sentry · calendar · email · terminal · MCPs`  
`↓ buffers · commands · provenance ↓`  
`browser · desktop shell · terminal · agent`

Emphasize that no rendered frontend is the canonical state. The UI is a client; the command layer is the shared language of action.

### 9. Closing

End with a quiet invitation, not a sales crescendo:

**Your work changes shape. Your environment should too.**

Supporting line: **Compose what you need. Keep what matters.**

Actions: **Read the source** and **Enter Compos**.

## Visual system

- Background: warm ivory, not pure white.
- Primary ink: charcoal-black.
- Secondary ink: deep indigo.
- Supporting color: muted leaf green.
- Accent: tiny amounts of compos-eye vermilion for focus and active state.
- Typography: literary display serif paired with a precise humanist sans and a serious monospace. A combination such as Newsreader, Geist Sans, and IBM Plex Mono is appropriate.
- Layout: generous margins, editorial rhythm, visible baseline discipline, asymmetry balanced by the hero bird.
- Texture: subtle paper or ink texture only; never compromise text contrast.
- Components may use fine rules, cursor marks, nested parentheses, process lines, and provenance dots as recurring motifs.

## Motion and interaction

Keep motion sparse and meaningful:

- a cursor pulse;
- process lines that wake briefly as sections enter view;
- provenance dots traveling from person or agent into a shared buffer;
- the hero network may breathe almost imperceptibly.

Respect `prefers-reduced-motion`. No scroll hijacking, ornamental parallax, animated gradients, or looping mascot behavior.

## Avoid

- purple/blue AI gradients;
- glowing orbs, brains, robots, sparkles, or circuit-board animals;
- fake editor screenshots or illegible decorative code;
- chatbot-first framing;
- leading with “Emacs rebuilt” or treating compatibility as the product;
- describing ephemeral apps as throwaway data, disposable code, or generated UI gimmicks;
- implying that every buffer is visually plain text;
- glassmorphism and stacks of rounded feature cards;
- claims such as “10×,” “revolutionary,” or “the future of coding”;
- faux-Indian motifs, mandalas, temple silhouettes, or national-color branding;
- presenting Compos as an IDE skin or VS Code competitor.

## Responsive and accessibility requirements

- Maintain a clear reading order with the hero image becoming a separate block on small screens.
- Minimum WCAG AA contrast for all copy and controls.
- Full keyboard access with visible focus states.
- Semantic headings, landmarks, and descriptive alternative text.
- The illustration is supplementary; the proposition must remain complete without it.
- Keep the page fast: responsive image sources, reserved image dimensions, and no heavy animation runtime.

## Asset

- Hero image: `apps/compos_ui/priv/static/images/compos-hero.png`
- Recommended alt text: `An Asian compos perched on a branch that becomes a network of editor panes and flowing processes.`
