# compos documentation

These docs explain compos to the person who uses it and to the agent that works
inside it. They are chapters: read in order for a guided path, or jump from the
index to one concept.

## How to use these docs

### If you are a person

1. Read [02. Concepts](<02. CONCEPTS.md>) first. It gives the five ideas every
   other chapter depends on.
2. Follow [Start here](#start-here) below. It is five short steps.
3. Use the [concept index](#concept-index-a-z) when you know what you want to
   do but not where it is written.
4. Read a chapter's "Start here" list, then the sections you need. Each chapter
   ends with "For the agent", which is the part to hand to an assistant.

### If you are an agent

1. Begin with [02. Concepts](<02. CONCEPTS.md>), then
   [15. Under the hood](<15. UNDER THE HOOD.md>). Together they say how the
   editor is built and what the one rule is: Elixir supplies the mechanism,
   Scheme decides the policy.
2. Read [07. Agents](<07. AGENTS.md>) for chats, context, permissions and
   skills, and [09. Todos and workflows](<09. TODOS + WORKFLOWS.md>) for the
   shared task list.
3. Use the [concept index](#concept-index-a-z) to find the chapter for a task.
4. Read the reference document named in the last column before you change a
   subsystem. Those documents hold the durable rules.
5. The user manual is generated from the live registries. Find commands, keys
   and how-to entries in [FURTHER READING/manual](FURTHER READING/manual/README.md).

## Start here

Do these five things in order. Each one takes one chapter.

1. **Connect a model.** Install compos and connect the agent to the editor.
   See [01. Set up compos](<01. SETUP.md>) and
   [08. Models and connectors](<08. MODELS + CONNECTORS.md>).
2. **Open a file and edit it.** Learn the keys you will use all day.
   See [04. Everyday editing](<04. EVERYDAY EDITING.md>).
3. **Start a chat.** A chat is a buffer, and the agent acts in the same editor
   you see. See [07. Agents](<07. AGENTS.md>).
4. **Start a task.** You and the agent share one todo list.
   See [09. Todos and workflows](<09. TODOS + WORKFLOWS.md>).
5. **Ask for a change.** Tell the agent what you want. It writes Scheme in the
   live editor, so no restart is needed.
   See [13. Extend](<13. EXTEND.md>).

## The chapters

1. [Set up compos](<01. SETUP.md>) - install the binary, run it, and connect an
   agent. [For the person](<01. SETUP.md#for-the-person>) |
   [For the agent](<01. SETUP.md#for-the-agent>).
2. [Concepts](<02. CONCEPTS.md>) - the five ideas to know first, and where each
   one lives. [Start here](<02. CONCEPTS.md#start-here>) |
   [What compos is](<02. CONCEPTS.md#what-compos-is>) |
   [Buffers](<02. CONCEPTS.md#buffers>) |
   [Frame, layout, pane, window](<02. CONCEPTS.md#frame-layout-pane-window>) |
   [Groups](<02. CONCEPTS.md#groups>) |
   [Modes](<02. CONCEPTS.md#modes>) |
   [Commands and keys](<02. CONCEPTS.md#commands-and-keys>) |
   [Lists](<02. CONCEPTS.md#lists>) |
   [Popups](<02. CONCEPTS.md#popups>) |
   [Scheme is the API](<02. CONCEPTS.md#scheme-is-the-api>).
3. [Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md>) - where work
   appears and how to move around it.
   [Start here](<03. BUFFERS, PANES, WINDOWS.md#start-here>) |
   [The parts, from the outside in](<03. BUFFERS, PANES, WINDOWS.md#the-parts-from-the-outside-in>) |
   [Buffers](<03. BUFFERS, PANES, WINDOWS.md#buffers>) |
   [Windows are stacks](<03. BUFFERS, PANES, WINDOWS.md#windows-are-stacks>) |
   [Closing is not killing](<03. BUFFERS, PANES, WINDOWS.md#closing-is-not-killing>) |
   [Moving between windows](<03. BUFFERS, PANES, WINDOWS.md#moving-between-windows>) |
   [Layouts](<03. BUFFERS, PANES, WINDOWS.md#layouts>) |
   [Where a new buffer goes](<03. BUFFERS, PANES, WINDOWS.md#where-a-new-buffer-goes>) |
   [Peek and popups](<03. BUFFERS, PANES, WINDOWS.md#peek-and-popups>).
4. [Everyday editing](<04. EVERYDAY EDITING.md>) - files, search, replace,
   undo, the kill ring, keys and palettes.
   [Start here](<04. EVERYDAY EDITING.md#start-here>) |
   [Files](<04. EVERYDAY EDITING.md#files>) |
   [Dired](<04. EVERYDAY EDITING.md#dired>) |
   [The project](<04. EVERYDAY EDITING.md#the-project>) |
   [Search in a buffer](<04. EVERYDAY EDITING.md#search-in-a-buffer>) |
   [Replace](<04. EVERYDAY EDITING.md#replace>) |
   [Go to a place](<04. EVERYDAY EDITING.md#go-to-a-place>) |
   [Undo](<04. EVERYDAY EDITING.md#undo>) |
   [The kill ring](<04. EVERYDAY EDITING.md#the-kill-ring>) |
   [The mark ring](<04. EVERYDAY EDITING.md#the-mark-ring>) |
   [Registers](<04. EVERYDAY EDITING.md#registers>) |
   [Bookmarks](<04. EVERYDAY EDITING.md#bookmarks>) |
   [The prefix argument](<04. EVERYDAY EDITING.md#the-prefix-argument>) |
   [Completion](<04. EVERYDAY EDITING.md#completion>) |
   [The two palettes](<04. EVERYDAY EDITING.md#the-two-palettes>) |
   [Menus](<04. EVERYDAY EDITING.md#menus>) |
   [Text size](<04. EVERYDAY EDITING.md#text-size>) |
   [Visual line wrap](<04. EVERYDAY EDITING.md#visual-line-wrap>) |
   [cua-mode](<04. EVERYDAY EDITING.md#cua-mode>) |
   [Vim keys](<04. EVERYDAY EDITING.md#vim-keys>).
5. [Working on code](<05. CODE.md>) - modes, structure, the REPL, build, diff,
   git, provenance and worktrees.
   [Start here](<05. CODE.md#start-here>) |
   [Open a project and a file](<05. CODE.md#open-a-project-and-a-file>) |
   [A mode for every language](<05. CODE.md#a-mode-for-every-language>) |
   [Read code by its structure](<05. CODE.md#read-code-by-its-structure>) |
   [The Scheme IDE and its REPL](<05. CODE.md#the-scheme-ide-and-its-repl>) |
   [Language servers](<05. CODE.md#language-servers>) |
   [Structural editing with paredit](<05. CODE.md#structural-editing-with-paredit>) |
   [Build, errors, and shells](<05. CODE.md#build-errors-and-shells>) |
   [The diff](<05. CODE.md#the-diff>) |
   [Git and jj](<05. CODE.md#git-and-jj>) |
   [Provenance: who wrote this](<05. CODE.md#provenance-who-wrote-this>) |
   [Worktrees and task workspaces](<05. CODE.md#worktrees-and-task-workspaces>) |
   [Remote files](<05. CODE.md#remote-files>) |
   [Format and indent](<05. CODE.md#format-and-indent>).
6. [Writing](<06. WRITING.md>) - Markdown, Morg, Org, blocks, notes, PDFs and
   slides.
   [Start here](<06. WRITING.md#start-here>) |
   [Markdown pages](<06. WRITING.md#markdown-pages>) |
   [Folding and moving in Morg](<06. WRITING.md#folding-and-moving-in-morg>) |
   [TODO states and the agenda](<06. WRITING.md#todo-states-and-the-agenda>) |
   [Fenced blocks](<06. WRITING.md#fenced-blocks>) |
   [Asking the model inside a document](<06. WRITING.md#asking-the-model-inside-a-document>) |
   [Org files](<06. WRITING.md#org-files>) |
   [Notes on a document](<06. WRITING.md#notes-on-a-document>) |
   [PDF documents](<06. WRITING.md#pdf-documents>) |
   [The writing workspace](<06. WRITING.md#the-writing-workspace>) |
   [Slide decks](<06. WRITING.md#slide-decks>) |
   [Made images](<06. WRITING.md#made-images>).
7. [Agents](<07. AGENTS.md>) - chats, the chat list, permissions, context,
   steering, subagents, skills and prompts.
   [Start here](<07. AGENTS.md#start-here>) |
   [Chats](<07. AGENTS.md#chats>) |
   [The chat list](<07. AGENTS.md#the-chat-list>) |
   [Permission answers](<07. AGENTS.md#permission-answers>) |
   [Context: visible buffers, companions, group members](<07. AGENTS.md#context-visible-buffers-companions-group-members>) |
   [Steering and the queue](<07. AGENTS.md#steering-and-the-queue>) |
   [Subagents](<07. AGENTS.md#subagents>) |
   [Skills](<07. AGENTS.md#skills>) |
   [Prompts](<07. AGENTS.md#prompts>) |
   [Tool results](<07. AGENTS.md#tool-results>) |
   [Abort, unstick, heal](<07. AGENTS.md#abort-unstick-heal>) |
   [Todos and events](<07. AGENTS.md#todos-and-events>).
8. [Models and connectors](<08. MODELS + CONNECTORS.md>) - connect a model,
   choose it, and set its tools, presets and secrets.
   [Start here](<08. MODELS + CONNECTORS.md#start-here>) |
   [A connector runs a model](<08. MODELS + CONNECTORS.md#a-connector-runs-a-model>) |
   [Connect and test a connector](<08. MODELS + CONNECTORS.md#connect-and-test-a-connector>) |
   [Choose the model with C-c b](<08. MODELS + CONNECTORS.md#choose-the-model-with-c-c-b>) |
   [A preset gives each job one model](<08. MODELS + CONNECTORS.md#a-preset-gives-each-job-one-model>) |
   [A bundle is a whole setup under a name](<08. MODELS + CONNECTORS.md#a-bundle-is-a-whole-setup-under-a-name>) |
   [MCP servers and the MCP hub](<08. MODELS + CONNECTORS.md#mcp-servers-and-the-mcp-hub>) |
   [Permissions and the sandbox](<08. MODELS + CONNECTORS.md#permissions-and-the-sandbox>) |
   [JEV and the fast model](<08. MODELS + CONNECTORS.md#jev-and-the-fast-model>) |
   [Secrets come from the key chain](<08. MODELS + CONNECTORS.md#secrets-come-from-the-key-chain>) |
   [The model catalog and its rules](<08. MODELS + CONNECTORS.md#the-model-catalog-and-its-rules>).
9. [Todos and workflows](<09. TODOS + WORKFLOWS.md>) - one shared task list,
   the event bus, listeners, workflows, cron and webhooks.
   [Start here](<09. TODOS + WORKFLOWS.md#start-here>) |
   [One list for the person and the agent](<09. TODOS + WORKFLOWS.md#one-list-for-the-person-and-the-agent>) |
   [The task is the record](<09. TODOS + WORKFLOWS.md#the-task-is-the-record>) |
   [Working a task](<09. TODOS + WORKFLOWS.md#working-a-task>) |
   [The list and the task page](<09. TODOS + WORKFLOWS.md#the-list-and-the-task-page>) |
   [Assigning, handover and review](<09. TODOS + WORKFLOWS.md#assigning-handover-and-review>) |
   [The event bus](<09. TODOS + WORKFLOWS.md#the-event-bus>) |
   [Listeners](<09. TODOS + WORKFLOWS.md#listeners>) |
   [Workflows](<09. TODOS + WORKFLOWS.md#workflows>) |
   [Cron](<09. TODOS + WORKFLOWS.md#cron>) |
   [Webhooks](<09. TODOS + WORKFLOWS.md#webhooks>) |
   [Notifications](<09. TODOS + WORKFLOWS.md#notifications>) |
   [Decide](<09. TODOS + WORKFLOWS.md#decide>) |
   [Reference](<09. TODOS + WORKFLOWS.md#reference>).
10. [Apps](<10. APPS.md>) - a list with a page for each row, and the same
    actions on both.
    [Start here](<10. APPS.md#start-here>) |
    [What an app is](<10. APPS.md#what-an-app-is>) |
    [The list keys](<10. APPS.md#the-list-keys>) |
    [Pages](<10. APPS.md#pages>) |
    [Actions](<10. APPS.md#actions>) |
    [Apps you have now](<10. APPS.md#apps-you-have-now>) |
    [The app registry](<10. APPS.md#the-app-registry>) |
    [Getting a new app](<10. APPS.md#getting-a-new-app>).
11. [Connected apps](<11. CONNECTED APPS.md>) - mail, Google, WhatsApp,
    iMessage, IRC, feeds, Sentry, Linear, web pages, Chrome, Spotify, Kindle.
    [Start here](<11. CONNECTED APPS.md#start-here>) |
    [Mail](<11. CONNECTED APPS.md#mail>) |
    [Google Workspace](<11. CONNECTED APPS.md#google-workspace>) |
    [WhatsApp](<11. CONNECTED APPS.md#whatsapp>) |
    [iMessage and SMS](<11. CONNECTED APPS.md#imessage-and-sms>) |
    [IRC](<11. CONNECTED APPS.md#irc>) |
    [Feeds](<11. CONNECTED APPS.md#feeds>) |
    [Sentry](<11. CONNECTED APPS.md#sentry>) |
    [Linear](<11. CONNECTED APPS.md#linear>) |
    [Web pages](<11. CONNECTED APPS.md#web-pages>) |
    [Your Chrome](<11. CONNECTED APPS.md#your-chrome>) |
    [Spotify](<11. CONNECTED APPS.md#spotify>) |
    [Kindle](<11. CONNECTED APPS.md#kindle>) |
    [Add another service](<11. CONNECTED APPS.md#add-another-service>).
12. [Customize](<12. CUSTOMIZE.md>) - settings, faces, keys, hooks, advice,
    secrets and your own files.
    [Start here](<12. CUSTOMIZE.md#start-here>) |
    [Settings](<12. CUSTOMIZE.md#settings>) |
    [Appearance](<12. CUSTOMIZE.md#appearance>) |
    [Keys](<12. CUSTOMIZE.md#keys>) |
    [Hooks](<12. CUSTOMIZE.md#hooks>) |
    [Advice](<12. CUSTOMIZE.md#advice>) |
    [Secrets](<12. CUSTOMIZE.md#secrets>) |
    [Your files](<12. CUSTOMIZE.md#your-files>) |
    [Groups and their config](<12. CUSTOMIZE.md#groups-and-their-config>).
13. [Extend](<13. EXTEND.md>) - packages, commands, modes, keymaps, hooks,
    components, blocks, apps and workflows.
    [Start here](<13. EXTEND.md#start-here>) |
    [Packages](<13. EXTEND.md#packages>) |
    [Commands](<13. EXTEND.md#commands>) |
    [Modes](<13. EXTEND.md#modes>) |
    [Keymaps](<13. EXTEND.md#keymaps>) |
    [Hooks](<13. EXTEND.md#hooks>) |
    [Components and ComposML](<13. EXTEND.md#components-and-composml>) |
    [Blocks](<13. EXTEND.md#blocks>) |
    [Apps](<13. EXTEND.md#apps>) |
    [Workflows](<13. EXTEND.md#workflows>) |
    [Skills](<13. EXTEND.md#skills>) |
    [Try it live](<13. EXTEND.md#try-it-live>) |
    [Watch out](<13. EXTEND.md#watch-out>).
14. [Sessions and sharing](<14. SESSIONS + SHARING.md>) - what comes back after
    a restart, frames, several editors, the phone and buffer links.
    [Start here](<14. SESSIONS + SHARING.md#start-here>) |
    [What comes back](<14. SESSIONS + SHARING.md#what-comes-back>) |
    [Restart the editor](<14. SESSIONS + SHARING.md#restart-the-editor>) |
    [Groups and frames](<14. SESSIONS + SHARING.md#groups-and-frames>) |
    [More than one editor](<14. SESSIONS + SHARING.md#more-than-one-editor>) |
    [The phone](<14. SESSIONS + SHARING.md#the-phone>) |
    [Share a link to a buffer](<14. SESSIONS + SHARING.md#share-a-link-to-a-buffer>) |
    [Two machines, one buffer](<14. SESSIONS + SHARING.md#two-machines-one-buffer>) |
    [Record a session](<14. SESSIONS + SHARING.md#record-a-session>) |
    [Screenshots](<14. SESSIONS + SHARING.md#screenshots>).
15. [Under the hood](<15. UNDER THE HOOD.md>) - the daemon, the one rule,
    processes, the buffer store, the socket and packages.
    [Start here](<15. UNDER THE HOOD.md#start-here>) |
    [The daemon](<15. UNDER THE HOOD.md#the-daemon>) |
    [Elixir mechanism, Scheme policy](<15. UNDER THE HOOD.md#elixir-mechanism-scheme-policy>) |
    [Processes, lanes and threads](<15. UNDER THE HOOD.md#processes-lanes-and-threads>) |
    [The buffer store](<15. UNDER THE HOOD.md#the-buffer-store>) |
    [The screen and the browser](<15. UNDER THE HOOD.md#the-screen-and-the-browser>) |
    [The MCP socket](<15. UNDER THE HOOD.md#the-mcp-socket>) |
    [Messages, telemetry and performance](<15. UNDER THE HOOD.md#messages-telemetry-and-performance>) |
    [Packages and load order](<15. UNDER THE HOOD.md#packages-and-load-order>).
16. [Troubleshooting](<16. TROUBLESHOOTING.md>) - ask the editor, read the
    messages, and report a problem.
    [Start here](<16. TROUBLESHOOTING.md#start-here>) |
    [Ask the editor](<16. TROUBLESHOOTING.md#ask-the-editor>) |
    [Messages](<16. TROUBLESHOOTING.md#messages>) |
    [A chat does not answer](<16. TROUBLESHOOTING.md#a-chat-does-not-answer>) |
    [The editor is slow or freezes](<16. TROUBLESHOOTING.md#the-editor-is-slow-or-freezes>) |
    [A change does not appear](<16. TROUBLESHOOTING.md#a-change-does-not-appear>) |
    [Errors and provenance](<16. TROUBLESHOOTING.md#errors-and-provenance>) |
    [How to report](<16. TROUBLESHOOTING.md#how-to-report>).

## Concept index (A-Z)

Each row gives the concept, the chapter that teaches it, and the reference
document that holds its rules.

| Concept | Chapter | Reference |
| --- | --- | --- |
| Advice | [12. Customize](<12. CUSTOMIZE.md#advice>) | [ADVICE.md](<FURTHER READING/ADVICE.md>) |
| Agenda | [6. Writing](<06. WRITING.md#todo-states-and-the-agenda>) | [ORG-MODE-PLAN.md](<FURTHER READING/internal/ORG-MODE-PLAN.md>) |
| Agents | [7. Agents](<07. AGENTS.md>) | [LEARN COMPOS.md](<FURTHER READING/LEARN COMPOS.md>) |
| Annotation (notes) | [6. Writing](<06. WRITING.md#notes-on-a-document>) | [ANNOTATIONS.md](<FURTHER READING/ANNOTATIONS.md>) |
| Apps | [10. Apps](<10. APPS.md>) | [COMPONENTS.md](<FURTHER READING/COMPONENTS.md>) |
| Architecture | [15. Under the hood](<15. UNDER THE HOOD.md>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Async work (tasks) | [15. Under the hood](<15. UNDER THE HOOD.md#processes-lanes-and-threads>) | [BEAM-POWER.md](<FURTHER READING/BEAM-POWER.md>) |
| Blocks (fenced) | [6. Writing](<06. WRITING.md#fenced-blocks>) | [BLOCKS.md](<FURTHER READING/BLOCKS.md>) |
| Bookmarks | [4. Everyday editing](<04. EVERYDAY EDITING.md#bookmarks>) | - |
| Browse (web pages) | [11. Connected apps](<11. CONNECTED APPS.md#web-pages>) | [BROWSE.md](<FURTHER READING/BROWSE.md>) |
| Buffer | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#buffers>) | [BUFFER.md](<FURTHER READING/BUFFER.md>) |
| Buffer link | [14. Sessions and sharing](<14. SESSIONS + SHARING.md#share-a-link-to-a-buffer>) | - |
| Buffer store | [15. Under the hood](<15. UNDER THE HOOD.md#the-buffer-store>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Build and compile | [5. Working on code](<05. CODE.md#build-errors-and-shells>) | - |
| Bundles | [8. Models and connectors](<08. MODELS + CONNECTORS.md#a-bundle-is-a-whole-setup-under-a-name>) | - |
| Chat | [7. Agents](<07. AGENTS.md#chats>) | [CHAT-LIST.md](<FURTHER READING/CHAT-LIST.md>) |
| Chat list | [7. Agents](<07. AGENTS.md#the-chat-list>) | [CHAT-LIST.md](<FURTHER READING/CHAT-LIST.md>) |
| Chrome extension | [11. Connected apps](<11. CONNECTED APPS.md#your-chrome>) | [CHROME_EXTENSION.md](<FURTHER READING/CHROME_EXTENSION.md>) |
| Code browsing | [5. Working on code](<05. CODE.md#read-code-by-its-structure>) | [CODEBROWSER.md](<FURTHER READING/CODEBROWSER.md>) |
| Commands | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-two-palettes>) | [COMMANDS.md](<FURTHER READING/COMMANDS.md>) |
| Companions | [7. Agents](<07. AGENTS.md#context-visible-buffers-companions-group-members>) | [AGENT CONTEXT MANAGEMENT.md](<FURTHER READING/AGENT CONTEXT MANAGEMENT.md>) |
| Completion | [4. Everyday editing](<04. EVERYDAY EDITING.md#completion>) | [COMPLETION.md](<FURTHER READING/COMPLETION.md>) |
| Components and ComposML | [13. Extend](<13. EXTEND.md#components-and-composml>) | [COMPOSML.md](<FURTHER READING/COMPOSML.md>) |
| Connector | [8. Models and connectors](<08. MODELS + CONNECTORS.md#a-connector-runs-a-model>) | - |
| Context (agent) | [7. Agents](<07. AGENTS.md#context-visible-buffers-companions-group-members>) | [AGENT CONTEXT MANAGEMENT.md](<FURTHER READING/AGENT CONTEXT MANAGEMENT.md>) |
| Cron | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#cron>) | - |
| C-u (prefix argument) | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-prefix-argument>) | [C-u.md](<FURTHER READING/C-u.md>) |
| cua-mode | [4. Everyday editing](<04. EVERYDAY EDITING.md#cua-mode>) | [cua-mode.md](<FURTHER READING/cua-mode.md>) |
| Customize | [12. Customize](<12. CUSTOMIZE.md>) | [VARIABLES.md](<FURTHER READING/VARIABLES.md>) |
| Daemon | [15. Under the hood](<15. UNDER THE HOOD.md#the-daemon>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Decide | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#decide>) | - |
| Diff | [5. Working on code](<05. CODE.md#the-diff>) | - |
| Dired | [4. Everyday editing](<04. EVERYDAY EDITING.md#dired>) | - |
| Display a buffer | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#where-a-new-buffer-goes>) | [DISPLAY-BUFFER.md](<FURTHER READING/DISPLAY-BUFFER.md>) |
| Errors | [16. Troubleshooting](<16. TROUBLESHOOTING.md#errors-and-provenance>) | [KNOWN-FAILURES.md](<FURTHER READING/internal/KNOWN-FAILURES.md>) |
| eval-expression (M-:) | [12. Customize](<12. CUSTOMIZE.md#start-here>) | - |
| Event bus | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#the-event-bus>) | [EVENT BUS.md](<FURTHER READING/EVENT BUS.md>) |
| Extend | [13. Extend](<13. EXTEND.md>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Faces | [12. Customize](<12. CUSTOMIZE.md#appearance>) | [FACES.md](<FURTHER READING/FACES.md>) |
| Feeds | [11. Connected apps](<11. CONNECTED APPS.md#feeds>) | - |
| File | [4. Everyday editing](<04. EVERYDAY EDITING.md#files>) | [FILE-VIEW.md](<FURTHER READING/FILE-VIEW.md>) |
| Fold | [6. Writing](<06. WRITING.md#folding-and-moving-in-morg>) | [MARKDOWN.md](<FURTHER READING/MARKDOWN.md>) |
| Frame | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#the-parts-from-the-outside-in>) | [WINDOWS.md](<FURTHER READING/WINDOWS.md>) |
| Git | [5. Working on code](<05. CODE.md#git-and-jj>) | [COMMITS.md](<FURTHER READING/COMMITS.md>) |
| Google Workspace | [11. Connected apps](<11. CONNECTED APPS.md#google-workspace>) | [features/GOOGLE.md](<FURTHER READING/features/GOOGLE.md>) |
| Group | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#start-here>) | [groups.md](<FURTHER READING/groups.md>) |
| Group modes | [12. Customize](<12. CUSTOMIZE.md#groups-and-their-config>) | [GROUP-MODES.md](<FURTHER READING/internal/GROUP-MODES.md>) |
| Handheld (phone) | [14. Sessions and sharing](<14. SESSIONS + SHARING.md#the-phone>) | [HANDHELD.md](<FURTHER READING/HANDHELD.md>) |
| Hooks | [12. Customize](<12. CUSTOMIZE.md#hooks>) | [HOOKS.md](<FURTHER READING/HOOKS.md>) |
| iMessage and SMS | [11. Connected apps](<11. CONNECTED APPS.md#imessage-and-sms>) | - |
| IRC | [11. Connected apps](<11. CONNECTED APPS.md#irc>) | - |
| JEV (fast model) | [8. Models and connectors](<08. MODELS + CONNECTORS.md#jev-and-the-fast-model>) | - |
| jj | [5. Working on code](<05. CODE.md#git-and-jj>) | [COMMITS.md](<FURTHER READING/COMMITS.md>) |
| Keymaps | [12. Customize](<12. CUSTOMIZE.md#keys>) | [KEYMAPS.md](<FURTHER READING/KEYMAPS.md>) |
| Kill ring | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-kill-ring>) | [KILL.md](<FURTHER READING/KILL.md>) |
| Kindle | [11. Connected apps](<11. CONNECTED APPS.md#kindle>) | - |
| Language server | [5. Working on code](<05. CODE.md#language-servers>) | - |
| Layout | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#layouts>) | [WINDOWS-SPEC.md](<FURTHER READING/internal/WINDOWS-SPEC.md>) |
| Linear | [11. Connected apps](<11. CONNECTED APPS.md#linear>) | - |
| List mode | [10. Apps](<10. APPS.md#the-list-keys>) | [LISTS.md](<FURTHER READING/LISTS.md>) |
| Listeners | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#listeners>) | [EVENT BUS.md](<FURTHER READING/EVENT BUS.md>) |
| Load order | [15. Under the hood](<15. UNDER THE HOOD.md#packages-and-load-order>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Mail | [11. Connected apps](<11. CONNECTED APPS.md#mail>) | - |
| Mark and point | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-mark-ring>) | - |
| Markdown | [6. Writing](<06. WRITING.md#markdown-pages>) | [MARKDOWN.md](<FURTHER READING/MARKDOWN.md>) |
| MCP | [8. Models and connectors](<08. MODELS + CONNECTORS.md#mcp-servers-and-the-mcp-hub>) | [mcp-proxy.html](<FURTHER READING/internal/protos/mcp-proxy.html>) |
| Menus | [4. Everyday editing](<04. EVERYDAY EDITING.md#menus>) | - |
| Model | [8. Models and connectors](<08. MODELS + CONNECTORS.md#choose-the-model-with-c-c-b>) | - |
| Modes | [5. Working on code](<05. CODE.md#a-mode-for-every-language>) | [MODES.md](<FURTHER READING/MODES.md>) |
| Morg | [6. Writing](<06. WRITING.md#folding-and-moving-in-morg>) | [MORG-DEMO.md](<FURTHER READING/MORG-DEMO.md>) |
| Notes | [6. Writing](<06. WRITING.md#notes-on-a-document>) | [ANNOTATIONS.md](<FURTHER READING/ANNOTATIONS.md>) |
| Notifications | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#notifications>) | - |
| Org files | [6. Writing](<06. WRITING.md#org-files>) | [ORG-MODE-PLAN.md](<FURTHER READING/internal/ORG-MODE-PLAN.md>) |
| Outline | [5. Working on code](<05. CODE.md#read-code-by-its-structure>) | [CODEBROWSER.md](<FURTHER READING/CODEBROWSER.md>) |
| Packages | [13. Extend](<13. EXTEND.md#packages>) | [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) |
| Pane | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#the-parts-from-the-outside-in>) | [PANES.md](<FURTHER READING/PANES.md>) |
| Paredit | [5. Working on code](<05. CODE.md#structural-editing-with-paredit>) | - |
| PDF | [6. Writing](<06. WRITING.md#pdf-documents>) | [PDF-ANNOTATIONS.md](<FURTHER READING/PDF-ANNOTATIONS.md>) |
| Peek | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#peek-and-popups>) | [PEEK.md](<FURTHER READING/PEEK.md>) |
| Permission answers | [7. Agents](<07. AGENTS.md#permission-answers>) | - |
| Point | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-mark-ring>) | - |
| Popups | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#peek-and-popups>) | [POPUPS.md](<FURTHER READING/POPUPS.md>) |
| Prefix argument | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-prefix-argument>) | [C-u.md](<FURTHER READING/C-u.md>) |
| Presets | [8. Models and connectors](<08. MODELS + CONNECTORS.md#a-preset-gives-each-job-one-model>) | - |
| Processes and lanes | [15. Under the hood](<15. UNDER THE HOOD.md#processes-lanes-and-threads>) | [BEAM-POWER.md](<FURTHER READING/BEAM-POWER.md>) |
| Project | [4. Everyday editing](<04. EVERYDAY EDITING.md#the-project>) | - |
| Prompts | [7. Agents](<07. AGENTS.md#prompts>) | [PROMPTS.md](<FURTHER READING/PROMPTS.md>) |
| Provenance | [5. Working on code](<05. CODE.md#provenance-who-wrote-this>) | [PROVENANCE.md](<FURTHER READING/PROVENANCE.md>) |
| Registers | [4. Everyday editing](<04. EVERYDAY EDITING.md#registers>) | - |
| Remote files | [5. Working on code](<05. CODE.md#remote-files>) | - |
| Replace | [4. Everyday editing](<04. EVERYDAY EDITING.md#replace>) | - |
| Restart | [14. Sessions and sharing](<14. SESSIONS + SHARING.md#restart-the-editor>) | - |
| Review | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#assigning-handover-and-review>) | - |
| Scheme | [13. Extend](<13. EXTEND.md>) | [SCHEME-GOTCHAS.md](<FURTHER READING/SCHEME-GOTCHAS.md>) |
| Scheme IDE and REPL | [5. Working on code](<05. CODE.md#the-scheme-ide-and-its-repl>) | [TESTING.md](<FURTHER READING/TESTING.md>) |
| Search | [4. Everyday editing](<04. EVERYDAY EDITING.md#search-in-a-buffer>) | - |
| Secrets | [12. Customize](<12. CUSTOMIZE.md#secrets>) | - |
| Sentry | [11. Connected apps](<11. CONNECTED APPS.md#sentry>) | - |
| Sessions | [14. Sessions and sharing](<14. SESSIONS + SHARING.md>) | - |
| Sharing | [14. Sessions and sharing](<14. SESSIONS + SHARING.md#share-a-link-to-a-buffer>) | - |
| Shell | [5. Working on code](<05. CODE.md#build-errors-and-shells>) | - |
| Skills | [7. Agents](<07. AGENTS.md#skills>) | - |
| Slides | [6. Writing](<06. WRITING.md#slide-decks>) | - |
| Spotify | [11. Connected apps](<11. CONNECTED APPS.md#spotify>) | - |
| Subagents | [7. Agents](<07. AGENTS.md#subagents>) | - |
| Task | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#the-task-is-the-record>) | - |
| Text size | [4. Everyday editing](<04. EVERYDAY EDITING.md#text-size>) | - |
| Theme | [12. Customize](<12. CUSTOMIZE.md#appearance>) | [FACES.md](<FURTHER READING/FACES.md>) |
| Todo | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#one-list-for-the-person-and-the-agent>) | - |
| Tool results | [7. Agents](<07. AGENTS.md#tool-results>) | - |
| Troubleshooting | [16. Troubleshooting](<16. TROUBLESHOOTING.md>) | [KNOWN-FAILURES.md](<FURTHER READING/internal/KNOWN-FAILURES.md>) |
| Tutorial | [2. Concepts](<02. CONCEPTS.md#start-here>) | [TUTORIAL.md](<FURTHER READING/TUTORIAL.md>) |
| Undo | [4. Everyday editing](<04. EVERYDAY EDITING.md#undo>) | - |
| Variables | [12. Customize](<12. CUSTOMIZE.md#settings>) | [VARIABLES.md](<FURTHER READING/VARIABLES.md>) |
| Vim keys | [4. Everyday editing](<04. EVERYDAY EDITING.md#vim-keys>) | [cua-mode.md](<FURTHER READING/cua-mode.md>) |
| Visible buffers | [7. Agents](<07. AGENTS.md#context-visible-buffers-companions-group-members>) | [AGENT CONTEXT MANAGEMENT.md](<FURTHER READING/AGENT CONTEXT MANAGEMENT.md>) |
| Web pages | [11. Connected apps](<11. CONNECTED APPS.md#web-pages>) | [BROWSE.md](<FURTHER READING/BROWSE.md>) |
| WhatsApp | [11. Connected apps](<11. CONNECTED APPS.md#whatsapp>) | - |
| Windows | [3. Buffers, panes, windows](<03. BUFFERS, PANES, WINDOWS.md#windows-are-stacks>) | [WINDOWS.md](<FURTHER READING/WINDOWS.md>) |
| Workflows | [9. Todos and workflows](<09. TODOS + WORKFLOWS.md#workflows>) | - |
| Worktrees | [5. Working on code](<05. CODE.md#worktrees-and-task-workspaces>) | [WORKTREES.md](<FURTHER READING/WORKTREES.md>) |
| Writing workspace | [6. Writing](<06. WRITING.md#the-writing-workspace>) | - |

## Reference documents

The chapters link to these documents. This list keeps every reference reachable
from one page.

### Start and learn

- [INTRODUCTION.md](<FURTHER READING/INTRODUCTION.md>) - what compos is, in
  essay form.
- [LEARN COMPOS.md](<FURTHER READING/LEARN COMPOS.md>) - a guided path through
  the ideas.
- [TUTORIAL.md](<FURTHER READING/TUTORIAL.md>) - the in-editor tutorial.
- [ADVICE.md](<FURTHER READING/ADVICE.md>) - practical advice from use.
- [BEYOND-TOOLS.md](<FURTHER READING/BEYOND-TOOLS.md>) - the agent that acts in
  the editor.
- [EMACS-AS-AGENT-HARNESS.md](<FURTHER READING/EMACS-AS-AGENT-HARNESS.md>) - why
  an editor is the agent's home.
- [CORDIS-VS-EMACS.md](<FURTHER READING/CORDIS-VS-EMACS.md>) - Lisp, JavaScript
  and this design.
- [COMPOS-HOMEPAGE-BRIEF.md](<FURTHER READING/internal/COMPOS-HOMEPAGE-BRIEF.md>) - the
  short public description.

### Buffers, windows and groups

- [BUFFER.md](<FURTHER READING/BUFFER.md>) - the buffer, its text and its
  locals.
- [WINDOWS.md](<FURTHER READING/WINDOWS.md>) - windows, frames and the stack.
- [WINDOWS-SPEC.md](<FURTHER READING/internal/WINDOWS-SPEC.md>) - the window model.
- [windows-guide.svg](<assets/windows-guide.svg>) - one picture of the
  window model.
- [PANES.md](<FURTHER READING/PANES.md>) - panes and layouts.
- [POPUPS.md](<FURTHER READING/POPUPS.md>) - transient and popup buffers.
- [PEEK.md](<FURTHER READING/PEEK.md>) - peek at a buffer.
- [DISPLAY-BUFFER.md](<FURTHER READING/DISPLAY-BUFFER.md>) - where a shown
  buffer goes.
- [FILE-VIEW.md](<FURTHER READING/FILE-VIEW.md>) - a file buffer and its view.
- [KILL.md](<FURTHER READING/KILL.md>) - the kill ring.
- [LISTS.md](<FURTHER READING/LISTS.md>) - the list mode all apps share.
- [groups.md](<FURTHER READING/groups.md>) - groups and their isolation.
- [GROUP-MODES.md](<FURTHER READING/internal/GROUP-MODES.md>) - a mode for a group.
- [HANDHELD.md](<FURTHER READING/HANDHELD.md>) - the phone client.

### Editing and commands

- [COMMANDS.md](<FURTHER READING/COMMANDS.md>) - what a command is.
- [KEYMAPS.md](<FURTHER READING/KEYMAPS.md>) - keys and keymaps.
- [COMPLETION.md](<FURTHER READING/COMPLETION.md>) - completion at point.
- [C-u.md](<FURTHER READING/C-u.md>) - the prefix argument.
- [cua-mode.md](<FURTHER READING/cua-mode.md>) - CUA and Vim keys.
- [VISUAL-LINE-WRAP-MAP.md](<FURTHER READING/internal/VISUAL-LINE-WRAP-MAP.md>) - soft
  wrap and the screen map.
- [MODES.md](<FURTHER READING/MODES.md>) - modes and their setup.

### Writing

- [MARKDOWN.md](<FURTHER READING/MARKDOWN.md>) - Markdown pages.
- [BLOCKS.md](<FURTHER READING/BLOCKS.md>) - fenced blocks and their runners.
- [editor/blocks/diff-block.md](<FURTHER READING/internal/examples/diff-block.md>) - the inline diff block.
- [ORG-MODE-PLAN.md](<FURTHER READING/internal/ORG-MODE-PLAN.md>) - Org support and its
  plan.
- [MORG-DEMO.md](<FURTHER READING/MORG-DEMO.md>) - Morg in use.
- [ANNOTATIONS.md](<FURTHER READING/ANNOTATIONS.md>) - notes on a document.
- [PDF-ANNOTATIONS.md](<FURTHER READING/PDF-ANNOTATIONS.md>) - notes on a PDF.

### Agents and automation

- [PROMPTS.md](<FURTHER READING/PROMPTS.md>) - prompt composition.
- [AGENT CONTEXT MANAGEMENT.md](<FURTHER READING/AGENT CONTEXT MANAGEMENT.md>) -
  what the agent sees.
- [CHAT-LIST.md](<FURTHER READING/CHAT-LIST.md>) - the chat list.
- [EVENT BUS.md](<FURTHER READING/EVENT BUS.md>) - events, listeners and
  workflows.
- [SIMPLIFY-SPEC.md](<FURTHER READING/internal/SIMPLIFY-SPEC.md>) - the agent and chat
  design.

### Models, tools and services

- [CHROME_EXTENSION.md](<FURTHER READING/CHROME_EXTENSION.md>) - the Chrome
  extension.
- [mcp-proxy.html](<FURTHER READING/internal/protos/mcp-proxy.html>) - the MCP socket.
- [BROWSE.md](<FURTHER READING/BROWSE.md>) - reading a web page.
- [features/GOOGLE.md](<FURTHER READING/features/GOOGLE.md>) - Google
  Workspace.

### Customize and extend

- [VARIABLES.md](<FURTHER READING/VARIABLES.md>) - settings.
- [FACES.md](<FURTHER READING/FACES.md>) - faces and appearance.
- [HOOKS.md](<FURTHER READING/HOOKS.md>) - hooks.
- [ADVICE.md](<FURTHER READING/ADVICE.md>) - advice around a function.
- [COMPONENTS.md](<FURTHER READING/COMPONENTS.md>) - the component contract.
- [COMPOSML.md](<FURTHER READING/COMPOSML.md>) - ComposML markup.
- [COMPOSML-COMPONENTS.md](<FURTHER READING/COMPOSML-COMPONENTS.md>) - the
  components in ComposML.

### Code and repository

- [CODEBROWSER.md](<FURTHER READING/CODEBROWSER.md>) - reading code as a tree.
- [CODE-BROWSER-PLAN.md](<FURTHER READING/internal/CODE-BROWSER-PLAN.md>) - its plan.
- [EDITING-SURFACE-SPEC.md](<FURTHER READING/internal/EDITING-SURFACE-SPEC.md>) - the
  editing surface.
- [PROVENANCE.md](<FURTHER READING/PROVENANCE.md>) - who wrote a line.
- [PROVENANCE-CRDT.md](<FURTHER READING/internal/PROVENANCE-CRDT.md>) - provenance and
  the CRDT.
- [WORKTREES.md](<FURTHER READING/WORKTREES.md>) - worktrees and task
  workspaces.
- [COMMITS.md](<FURTHER READING/COMMITS.md>) - how a commit message is written.
- [TESTING.md](<FURTHER READING/TESTING.md>) - how to test.
- [SCHEME-GOTCHAS.md](<FURTHER READING/SCHEME-GOTCHAS.md>) - builtins whose
  behaviour surprises.
- [SCHEME-THREADING.md](<FURTHER READING/SCHEME-THREADING.md>) - the threading
  rules.

### Under the hood

- [ARCHITECTURE.md](<FURTHER READING/ARCHITECTURE.md>) - the one rule and the
  layers.
- [BEAM-POWER.md](<FURTHER READING/BEAM-POWER.md>) - processes and the BEAM.
- [DESIGN-PORT.md](<FURTHER READING/internal/DESIGN-PORT.md>) - the design port.

### Manual

- [manual/README.md](<FURTHER READING/manual/README.md>) - the generated user
  manual.
- [manual/HOW-DO-I.md](<FURTHER READING/manual/HOW-DO-I.md>) - task entries.
- [manual/COMMANDS.md](<FURTHER READING/manual/COMMANDS.md>) - every command.
- [manual/KEYS.md](<FURTHER READING/manual/KEYS.md>) - every global key.

### Project and engineering notes

- [SIMPLIFY-AUDIT.md](<FURTHER READING/internal/SIMPLIFY-AUDIT.md>) - the current state
  and the queue.
- [KNOWN-FAILURES.md](<FURTHER READING/internal/KNOWN-FAILURES.md>) - tests that were
  already red.
- [CLEANUP-QUEUE.md](<FURTHER READING/internal/CLEANUP-QUEUE.md>) - the cleanup queue.
- [DOGFOOD-BENCH.md](<FURTHER READING/internal/DOGFOOD-BENCH.md>) - the dogfood
  benchmark.
- [SWITCHER-PERF-HANDOFF.md](<FURTHER READING/internal/SWITCHER-PERF-HANDOFF.md>) -
  switcher performance.
- [BUG-escaped-closure-handlers.md](<FURTHER READING/internal/BUG-escaped-closure-handlers.md>) -
  a closure-handler bug.
- [LEARN COMPOS.md](<FURTHER READING/LEARN COMPOS.md>) - the tutorial.
- [proposals/REACTIVITY.md](<FURTHER READING/internal/proposals/REACTIVITY.md>) - the
  reactivity proposal.
- [code-browse.html](<FURTHER READING/internal/protos/code-browse.html>) - the code browser
  prototype.
