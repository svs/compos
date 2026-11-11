# ComposML 1: semantic HTML for Compos

Status: first LiveView migration implemented; `codex/composml` is merged into main. This specification
was written before the migration. External XML/XSLT transport remains a separate
implementation stage, as described below.

## Implemented rendering interface

All three first-party LiveViews, both LiveComponents, their function components,
and both layouts now author templates with `~M`. Each LiveView/LiveComponent has
`composml/1`; its Phoenix `render/1` delegates through the shared dispatcher:

```elixir
Compos.Ui.Representation.render(view_module, assigns, :composml)
# %{format: :composml, content: %Phoenix.LiveView.Rendered{...}}
# or %{format: :html, content: ...} when composml/1 is absent
```

The dispatcher calls `composml/1` when available, otherwise `html/1` or the existing
`render/1`. An explicit `:html` preference selects `html/1` when present; a
ComposML-only view still reports `:composml`, never a falsely labelled HTML
fallback through its Phoenix wrapper. Rendering exceptions propagate. The normal browser transport remains Phoenix LiveView over HTML and
WebSocket diffs; this interface does not advertise a new HTTP XML endpoint.

`Compos.Ui.ComposML` implements the `~M` compiler using Phoenix's tracked tag
engine. It validates core semantic names and rejects generic div/span template
elements. Native document, form, and SVG tags remain available. Existing Markdown,
preview documents, and embedded applications retain their HTML content boundary.

ComposML introduces vocabulary, not syntax. Materialized `.composml` files use
`composml-mode` backed by the built-in HTML parser. Semantic queries live under
`priv/queries/composml`. The optional Elixir injection query maps `~M` bodies to
HEEx in clients that support injections and have that grammar installed. Phoenix
compiles the templates; no separate ComposML parser is shipped or compiled.

The base stylesheet gives semantic elements normal display defaults. Existing
theme variables, class styles, and new `face` attribute selectors coexist.
The dashboard and shared heading/action components now emit semantic Scheme
blocks, so these structures remain semantic when rendered dynamically.

The [current-frame specimen](examples/current-frame.composml) is grounded in the
rendered localhost:4004 page inspected on 2026-09-09. It is a proposed rendition,
not an implementation claim. Its repeated transcript entries and transport
bookkeeping are abbreviated.

## Purpose and boundary

The programming model is **XHTML → XSLT → ComposML**, with CSS styling the result
and Scheme owning editor interaction. A structured document can have multiple
programmable views. XSLT is a first-class transformation interface, not merely
an emergency compatibility conversion back to generic HTML.

ComposML describes what a rendered Compos interface contains: frames, windows,
buffers, modelines, completions, transcripts, and ordinary semantic documents.
LiveView transports and incrementally updates that interface. ComposML elements
remain visible in the browser DOM. They are not erased into generic HTML divs.

Version 1 covers every first-party LiveView template, its LiveComponents, function
components, and layouts. External documents, rendered Markdown, and embedded apps
remain content supplied to those views. Third-party Phoenix dashboard templates
are outside this migration.

Editor state, commands, keymaps, and interaction policy remain in Scheme. The
Elixir implementation supplies the missing compile-time mechanism: lowering
ComposML to Phoenix's tracked render representation. It does not move Scheme
policy into a second UI state machine.

## Rendering format and incremental adoption

Introduce a named `composml` format. A request for that representation uses a
view's ComposML renderer when one is provided; otherwise it falls back to the
existing HTML/LiveView representation. This is capability-based selection, not
content sniffing or an assumption that HTML renamed as ComposML has semantics.

```text
requested format = composml
  and the view provides composml → render its ComposML representation
  otherwise                     → render existing HTML/LiveView
```

Apply this shared dispatch contract to every first-party LiveView. Keep format
selection outside individual templates so views do not each implement slightly
different fallback logic. Existing HTML callers retain their current behavior.
The response must identify the representation actually selected; a fallback HTML
response must not advertise itself as a well-formed ComposML/XML document.

Transport negotiation and view rendering are distinct responsibilities. An HTTP
representation request negotiates the response format. A connected LiveView must
retain the selected representation across mounts, events, and patches, or perform
an explicit remount when it changes. XML document responses and LiveView diff
messages are different wire formats; requesting a semantic document must not
accidentally return a disconnected splash or silently attach a second editor
frame. The implementation must settle and test this boundary before advertising
the format as an external API.

Fallback is for an absent representation. Errors from an existing ComposML
renderer remain errors with useful diagnostics; do not catch every exception and
quietly serve unrelated HTML. Test a view with ComposML, a view without it, an
explicit HTML request, and a ComposML rendering failure.

Scheme selects documents, views, transforms, and commands. The Elixir layer
supplies format dispatch and Phoenix rendering/transport. Meaning is defined by
the shared vocabulary and schemas rather than by which implementation language
constructs the tree.

## Concrete syntax

ComposML is case-sensitive, UTF-8, explicitly nested markup. Materialized
standalone documents use `.composml` and must be well-formed XML: attributes are
quoted, entities are XML-safe, and every element is explicitly closed. They can
be parsed and transformed without running the application. Elixir templates use
the literal `~M` sigil and are a separate authoring layer, not XML documents to
feed directly to XSLT. The template syntax retains
HEEx expressions, directives, components, and slots so expressions have one
implementation and LiveView retains dependency tracking.

```composml
<c-frame id="editor" class="editor-root" phx-hook="Keys" data-frame={@frame}>
  <c-windows class="windows">
    <c-window :for={window <- @windows} id={"win-#{window.id}"} class="window">
      <c-buffer class="buffer" data-buf={window.buffer}>
        <c-line :for={line <- window.lines} class="line">{line.text}</c-line>
      </c-buffer>
      <c-modeline class="modeline">{window.name}</c-modeline>
    </c-window>
  </c-windows>
</c-frame>
```

Template elements have explicit matching closing tags or `/>`. Browser HTML void
elements retain their usual behavior, but XML export closes them. Template
attributes accept quoted strings, booleans, `{expression}`,
and `{attributes}` spreads. `:if`, `:for`, and `:let` preserve HEEx semantics.
`<.component>`, `<Module.component>`, and `<:slot>` retain their existing contracts.
Body expressions use `{expression}`; EEx blocks remain supported for conditionals,
loops, and existing templates. HTML comments and HEEx comments are supported.

Ordinary semantic HTML (`main`, `section`, `article`, `nav`, `header`, `footer`,
headings, paragraphs, lists, tables, links, buttons, forms, and media) is already
ComposML. Document infrastructure, style/script bodies, and SVG are retained.
Generic HTML `div` and `span` are replaced by semantic Compos elements or the
explicit neutral composition elements `c-group` and `c-text`. Unknown `c-*`
elements are compile errors; extensions must declare their meaning and lowering.

## Semantic vocabulary and browser representation

Every semantic element below retains its own name in the browser's light DOM.
No XSLT step, shadow root, JavaScript custom-element registration, or translation
to div/span is required. The base stylesheet supplies block defaults except for
inline `c-text`; all display behavior remains overridable by ordinary CSS.

| ComposML | Meaning | Default display |
| --- | --- | --- |
| `c-frame` | One editor client frame | block |
| `c-windows` | Window-tree container | block |
| `c-split` | Branch of the window tree | block |
| `c-window` | A window onto a buffer | block |
| `c-buffer` | Buffer rendering surface | block |
| `c-line` | A rendered text line | block |
| `c-modeline` | Frame or window status and controls | block |
| `c-headerline` | Persistent window context above buffer content | block |
| `c-buffer-name` | Buffer identity and modification state | inline |
| `c-mode` | Active major/minor mode label | inline |
| `c-position` | Position in a buffer | inline |
| `c-headline` | A structural section heading | block |
| `c-statusbar` | Collection of ongoing status indicators | block |
| `c-status` | One named operational state | inline |
| `c-progress` | Progress toward a known or unknown total | inline |
| `c-tabs` | Navigation choices for a named kind of target | block |
| `c-tab` | One target and its selection state | inline |
| `c-field` | Named metadata field, with optional label and value | block |
| `c-label` | Human-readable name of its associated item | inline |
| `c-metric` | Measurement with a name, value, and unit | inline |
| `c-key-hints` | Keyboard bindings and their descriptions | inline |
| `c-minibuffer` | Command input and completion surface | block |
| `c-completions` | Collection of completion choices | block |
| `c-completion` | One completion choice | block |
| `c-which-key` | Pending-key discovery surface | block |
| `c-transcript` | Ordered agent conversation surface | block |
| `c-user`, `c-agent` | User and agent transcript entries | block |
| `c-info`, `c-summary` | Informational and summary entries | block |
| `c-toolcall` | Tool invocation, identity, and execution state | block |
| `c-arguments` | Displayed invocation arguments | inline |
| `c-result` | Tool result content | block |
| `c-activity` | Current activity outside the persistent transcript | block |
| `c-prompt` | Input prompt with label, editor, and hints | block |
| `c-input` | Editor-owned input surface | inline |
| `c-cursor` | Editor caret, not a content character | inline |
| `c-toolbar` | Related action controls | block |
| `c-echo` | Editor feedback surface | block |
| `c-action` | An actionable block | block |
| `c-value` | A block's displayed value | block |
| `c-group` | Neutral block composition | block |
| `c-text` | Neutral inline composition | inline |

Meaning comes from the source element, independently of CSS classes. A tree-sitter
query must identify a window even when its class expression or styling changes.
Neutral composition is valid where no domain meaning exists; domain elements
should name actual editor structure, not be mechanically assigned to every div.

### Modelines, headlines, and status bars

These are first-class, distinct semantics even when they share visual styling.
A modeline describes the associated buffer/window; a headline introduces a
structural section; a status bar collects operational status. Do not represent
them as generic groups whose only distinguishing feature is a CSS class.

```composml
<c-modeline>
  <c-buffer-name modified="true">editor.scm</c-buffer-name>
  <c-mode>Scheme</c-mode>
  <c-position line="42" column="7" />
</c-modeline>
<c-headline level="2" folded="false">Rendering architecture</c-headline>
<c-statusbar>
  <c-status state="busy">Agent working</c-status>
  <c-progress value="3" max="8" />
</c-statusbar>
```

`modified` and `folded` are explicit string-valued states (`"true"`/`"false"`),
not HTML boolean attributes whose presence means true. `level` is a positive
heading depth; `line` is one-based and `column` follows the editor's displayed
column convention. Determinate progress supplies numeric `value` and positive
`max`; omitting `value` means indeterminate. `state` is an extensible operational
label, not a CSS color or a command. These attributes describe state; Scheme
continues to own state transitions and actions.

The DOM must contain real text for labels and positions, even where CSS adds
decoration. A position element with no children needs a component to supply its
visible/accessibility text; CSS-generated content is not the sole information
source. Likewise a progress element needs native progress or explicit progressbar
ARIA semantics. The examples describe vocabulary, not automatic widget behavior.

Native heading elements remain valid and preferred when HTML's heading semantics
are sufficient. A rendered `c-headline` must carry `role="heading"` and a matching
`aria-level`. A status bar is not automatically a live region: only indicators
whose changes should be announced receive suitable `role`/`aria-live` attributes.
Modelines do not imply a toolbar role unless their interaction follows that
accessibility pattern. Every interactive element needs native controls or
equivalent keyboard, focus, and accessibility behavior.

### Structure recovered from the current browser page

The actual page has three distinct strips: `.echo-bar` is a frame status bar with
group navigation; `.dash-persistent` is a window header line containing named
mode/group/preset fields and a summary action; `.modeline` is the buffer's lower
status line. These are not three spellings of the same element. `c-headerline`
is also distinct from `c-headline`, a heading in document content.

The `.ag-scroll` children are an ordered mixture of messages and tool calls.
Tool identity, state, arguments, duration, and results belong in explicit nodes
and attributes. Existing native `details`/`summary` can provide disclosure within
a `c-toolcall`; native buttons can provide activation within `c-action` and
`c-tab`. The grammar should not infer that a `details.ag-tool.done` is a completed
tool call from its styling. The transient `.ag-activity` indicator is a sibling
of the transcript; it must not become a historical message merely because it
contains text. The `.ag-inputrow` is a prompt with an editor-owned input surface.

Use a small compositional vocabulary: a named `c-field` for group/preset/project
metadata and a named `c-metric` for memory/duration/token measurements. Do not add
a new element for every label or CSS variant. Decorative separators and flexible
spacers may be expressed by CSS rather than cluttering the semantic document.

`c-input` and `c-cursor` preserve Compos's existing key/selection ownership and
byte-position accounting. They are not newly implemented native form controls.
Migration must retain the browser input hooks and explicit accessibility contract.
Likewise, `c-tabs` alone does not assert the ARIA tablist pattern; buttons remain
native controls and the application must implement that pattern before adding its
roles. Semantic domain labels must not promise unsupported keyboard behavior.

## CSS power and client compatibility

ComposML has the same CSS styling surface as HTML. Stylesheets can select semantic
element names and attributes directly, including child/sibling relationships,
`:has`, state pseudo-classes, and pseudo-elements. Flexbox, grid, positioning,
inheritance, custom properties, animations, and container queries remain available.
No restricted styling DSL is introduced. Existing CSS may change freely to target
the semantic vocabulary; byte-for-byte DOM or selector compatibility is not a goal.

Preserve behavior while migrating selectors: IDs, event payloads, caret byte
offsets, hook identity, conditional rendering, component boundaries, and native
form controls remain functional. Update CSS and JavaScript wherever they assume
div/span tag names. Classes may coexist with semantics during migration, but are
not the semantic contract. No invisible wrapper may break expected layout.

Semantic names do not automatically create native button, link, form, keyboard,
or accessibility behavior. Use native semantic HTML controls within ComposML
where those browser capabilities are needed. The existing LiveView browser
transport uses the HTML parser and MIME type; this must not dictate the canonical
document representation. XML serialization and browser serialization are explicit
boundaries. Both preserve ComposML semantic element names. Do not feed arbitrary
browser `outerHTML` directly to an XML parser and assume it is XHTML.

For example, `c-action > c-value > c-text[face="dim"]` should express the
summary-log block directly. Domain attributes and transport bindings can coexist:
`phx-click="block_click"`, `phx-value-win="80"`, and
`phx-value-id="summary-log"` retain the existing event contract. Phoenix owns its
generated `data-phx-id`. The grammar can read the domain structure in both source
templates and rendered markup without inferring it from `dseg-*` classes.

## Parsing and tooling contract

Reuse existing syntax parsers: HTML for browser markup, XML for canonical XML
exports, and HEEx for templates. Semantic queries match ordinary tag names;
new domain vocabulary does not require parser changes. Vocabulary validation
belongs to the ComposML compiler, not a separate syntax grammar.

Expressions must handle nested delimiters, quoted strings containing delimiters,
and multiline bodies. CSS/JavaScript bodies must not be mistaken for ComposML
expressions. Incremental parsing must recover locally on incomplete edits.
Syntactic tree construction does not imply semantic validity: the compiler must
also reject mismatched element names and unknown semantic vocabulary.

## External applications and semantic buffers

ComposML is also a document interface for external applications. A service can
publish structured documents directly; an adapter can project an existing HTML
page into the same model. These are two entry paths to one buffer representation.
This section defines the extension direction, not an implemented connector or an
expansion of the initial LiveView migration into a recruiting integration.

### Programmable views with XSLT

```text
Website / application API
          ↓
     XHTML document
          ↓
  XSLT view transformation
          ↓
   ComposML buffer
          ↓
     LiveView + CSS
```

An adapter normalizes existing HTML into well-formed XHTML; a cooperating API
can supply structured XML/XHTML directly. A registered XSLT stylesheet projects
that source into the ComposML view vocabulary. The same source can support a
shortlist, a candidate comparison, a pipeline, or a detail view. Stylesheets are
ordinary programmable artifacts that can be opened, queried, edited, versioned,
and selected by Scheme.

The canonical document contract must specify namespaces, XML version, and the
serialization of booleans, empty elements, entities, and embedded text. XPath
expressions must bind namespaces explicitly rather than depend on accidental
prefix spellings. Exact namespace URIs and the supported XSLT processor/version
remain design decisions to settle before the external transformation runtime is
implemented; the initial LiveView migration must not silently choose them by
serializing an HTML DOM.

Run transformations in the application runtime, with a selected maintained XSLT
processor; do not depend on a browser having an XSLT engine. Transformation output
is a document tree, which must enter the normal incremental render path. XSLT
does not justify replacing an entire interactive buffer with an opaque raw HTML
blob on every update. Preserve source record IDs through transformations so
selection, marks, actions, and evidence references survive changes of view.

Transformations project documents. Scheme commands and application adapters
perform edits and external actions, then refresh the source model. Do not assume
an arbitrary XSLT projection has an automatic inverse for writing edits back.
Processor resource access and extension functions belong to the registered
runtime contract, not to privileges granted by an imported stylesheet.

Grammar tooling must cover XML/XHTML, XSLT, XPath, ComposML, and CSS, with
appropriate embedded-language queries. ComposML reuses existing HTML/HEEx parsing; a complete external-application transformation feature requires the
remaining grammars and runtime contracts rather than claiming syntax highlighting
alone provides that feature.

For example, SVS Recruiting could expose roles, candidate records, and application
stages through an XHTML-style API. Compos could open a role as a buffer, navigate
and mark candidates, filter stages, compare candidates across windows, and route
actions through Scheme commands. Agents and tree-sitter queries would inspect the
same semantic records that the user sees.

### Domain vocabulary

Applications register versioned vocabulary schemas alongside the core Compos
vocabulary. A schema declares element names, attributes, identity, child structure,
and supported actions. For HTML delivery, use hyphenated names such as
`svs-candidate` and `svs-application`; XML namespace/export mappings may be declared
separately. Registering a domain vocabulary does not require changing core grammar
syntax. Tree-sitter captures domain element names and structure; schema-aware
validation and queries supply the application's meaning. Unknown core `c-*`
names remain errors. An unrecognized external vocabulary must remain inspectable
as a document and must not acquire executable actions merely by naming them.

Illustrative domain document (proposed schema, not the current ATS API):

```composml
<c-buffer source="svs:role/role-123" vocabulary="svs-recruiting@1">
  <svs-role record-id="role-123">
    <c-headline level="1" role="heading" aria-level="1">Platform engineer</c-headline>
    <svs-pipeline>
      <svs-application record-id="application-456" stage="shortlisted">
        <svs-candidate record-id="candidate-789">
          <c-headline level="2" role="heading" aria-level="2">Candidate name</c-headline>
          <svs-assessment dimension="role-fit">Assessment text</svs-assessment>
        </svs-candidate>
        <c-action command="svs-request-intro" target="application-456">
          <button type="button">Request introduction</button>
        </c-action>
      </svs-application>
    </svs-pipeline>
  </svs-role>
</c-buffer>
```

### Identity, evidence, refresh, and actions

Record identity is stable across refreshes and independent of DOM order, display
labels, and Phoenix patch IDs. Buffers retain their source and version/revision;
adapters preserve links or source ranges so a user can visit the original evidence.
Refresh reconciles records by identity, preserving point, marks, folds, and window
position where possible. An extracted interpretation of an arbitrary website is
distinguished from structure declared by the source application's own API.

Action references resolve through registered Scheme commands with declared input
schemas and effects. The application adapter owns endpoint/authentication details
and version/conflict handling. Credentials stay outside the document. Remote
markup is data: imported event handlers, scripts, or command names do not grant
authority to execute actions. Actions retain the source application's access rules
and any required user decision, including an explicit introduction request in the
recruiting example. Viewing or refreshing a document does not execute its actions.

A direct ComposML API can expose a richer and more stable model than a website
adapter. Adapters should preserve existing semantic HTML and add domain structure
only when supported by source evidence. Both paths retain ordinary CSS styling
and enter the normal buffer/command lifecycle rather than a separate application
shell.

## Compilation and safety

Parse and validate source names, preserving them in emitted markup. Never
perform a global textual replacement that could rewrite CSS, comments, string
literals, or expression content. Compile through Phoenix's tracked engine so
assign dependency tracking, streams, slots, event bindings, component identity,
escaping, and incremental updates remain intact. Do not serialize the whole view
to an opaque HTML string or mark ordinary text as safe.

Diagnostics retain the original file and source line. ComposML does not grant
permission to execute untrusted templates. Existing explicitly trusted raw HTML
boundaries stay explicit; expressions and attributes use Phoenix escaping.

## Acceptance conditions

1. Every first-party LiveView participates in the shared `composml` format
   contract. Missing representations fall back honestly to existing HTML/LiveView.
   Complete migration subsequently covers their LiveComponents and layouts too.
2. Desktop and mobile editor structures use domain elements; ordinary documents
   retain semantic HTML and neutral composition where appropriate.
3. Runtime checks cover semantic DOM output, dynamic values, branches, loops,
   slots, escaping, and events. Semantics survive rendering.
4. Existing editor, mobile, homepage, and transcript behavior tests pass, with
   selectors adapted to ComposML where necessary. CSS and browser assets are
   migrated to preserve layout and interactions, not old tag names.
5. Grammar corpus and source parsing cover all migrated templates without syntax
   errors, plus nested expressions, raw bodies, and incomplete edits.
6. Unknown semantic names and mismatched source closing tags fail compilation.
7. The compiler, grammar, queries, and migration live in the worktree and survive
   a normal clean build and daemon restart.


## Migration validation (2026-09-10)

The migration was built in branch `codex/composml` (now merged into main), based on `45ac86d3`, in the isolated
worktree `/private/tmp/compos-composml`. The running original checkout was not
restarted or changed by this migration.

- Focused compiler/dispatch, grammar, normal mode loading and reentry, and face
  CSS tests: 22 passed. The Scheme modeline suite also passed.
- Bundled Tree-sitter corpus: 62 passed. Every production `~M` body parses without
  errors, including layout CSS/JavaScript; semantic and injection queries compile.
- Complete isolated UI suite: 267 tests, 263 passed and four failures. The same
  four failures reproduce with the original base rendering modules: preview
  caret CSS dimensions, clipboard delivery for C-c l, modeline-info duplicate
  name count, and agent text-scale CSS expectations.
- Repository-wide `bin/test-fast 4` completed with additional core failures. It is
  not a passing acceptance run. Failures include unrelated Scheme/keybinding
  expectations, integration fixtures, sandbox-denied trash moves, and file-watch
  exhaustion. Those failures have not all been individually baselined.
- `git diff --check` passes. The stylesheet is served by the normal endpoint.

The renderer retains Phoenix tracked values and event bindings. Runtime tests
exercise editor/mobile rendering and interaction; no visual browser comparison
was performed. External XML transport, an XSLT processor, and remote application
adapters are specified extension points, not delivered integrations.

## Semantic lists and Notmuch

Current activation: enabled. The user chose to restore the semantic list and
message presentation after comparing it with the original UI.

A mode supplies domain structure and field roles; the shared list component owns
CSS layout, wrapping, selection, and navigation. Modes do not need separate
stylesheets. Optional theme rules can target domain names.

`define-list-mode!` accepts `collection` (an element name) and `composml` (a pure
`(buf entry) -> block` callback). Both are optional; modes without them retain
text rendering. The existing string-valued `key` callback supplies record identity.
The projection uses the same filtered/paged entries and text offsets as keyboard
commands, so a two-line text row remains one semantic item. Selection comes from
each window's point. DOM IDs have a window prefix; `record-id` is domain identity
independent of windows, labels, and row position.

```xml
<mailboxes class="semantic-list" role="list">
  <mailbox record-id="tag:inbox" query="tag:inbox" role="listitem"
           class="semantic-item" selected="true">
    <mailbox-name field="primary">Inbox</mailbox-name>
    <unread-count field="count">12</unread-count>
    <message-count field="count">184</message-count>
    <mail-query field="detail">tag:inbox</mail-query>
  </mailbox>
</mailboxes>
```

Shared field roles are `primary`, `secondary`, `trailing`, `count`, `tags`, and
`detail`. CSS selectors such as `.semantic-item > [field="primary"]` style every
mode consistently. `selected`, `marked`, and `unread` expose state independently
of color. A click focuses the row by stable key and calls the optional `on-click (buf entry)`
mode callback. Notmuch uses it to update the preview through the same path as Up/Down,
respecting `notmuch-auto-preview`. Clicking does not change bulk marks; `m`
continues to toggle those. Mailbox clicks retain focus-only behavior.
Refreshing and mode re-entry rebuild the projection; generated blocks are not
persisted in the desktop.

Notmuch provides `mailboxes/mailbox` and `mail-threads/mail-thread` collections.
Thread fields retain full subjects, participants, dates, and individual tags.
Both plain-message blocks and HTML mail previews expose `mail-message`, message
identity, sender/recipient/date fields, `mail-body`, and attachments with part IDs.
Original HTML mail bodies remain inside the existing sandboxed preview boundary.
Attachment and mail actions retain their existing commands.

Bare `mailbox` and `mailboxes` are registered domain names, parsed as semantic
names alongside hyphenated elements. They are light-DOM elements, not registered
Web Components; JavaScript custom-element registration is unnecessary. They are
not XHTML-standard vocabulary. XML export still requires the namespace/schema
contract described above.

Semantic-list validation: the final focused run passed 19 core and 16 UI tests;
the final message-renderer adjustment passed 15 core and four list UI tests.
The earlier duplicate grammar passed 63 corpus cases; it has since been removed in favor of existing parsers. The complete isolated UI suite now has
271 tests, with 267 passing and the same four baseline failures documented above.
The broader list/Notmuch run has 41 core tests with one previously observed
bulk-tag selection failure. A fresh repository-wide partitioned run completed
with core/integration failures; it is not green and those failures have not all
been individually baselined. No ComposML list test failed in that run.

The worktree preview on port 4024 was restarted and the normal loaded catalog
confirmed both list and mail semantic renderers. The original port 4004 daemon
was not restarted. Refresh the preview page to fetch the updated shared CSS.

### Mode-owned buffer roots

Block renderers may set the derived buffer-local `render-root` to a block
property list containing `tag` and `attrs`. List modes provide the same descriptor
through `composml-root (buf)`. LiveView validates it with the block vocabulary and
attribute allowlist. The root owns the existing layout class and scroll hook;
its DOM id remains window-scoped so two views of one mailbox have unique ids.
Modes express domain identity separately in semantic attributes. Mail supplies
`mailbox` with `source`, `profile`, and `query`; an email account address must come
from configuration, not be inferred from a database path. Without a descriptor,
the root is `c-buffer`.

Chat message bodies use `c-message-body`; questions contain `c-headline`,
`c-answers`, and `c-hint`. Native buttons retain their interaction behavior.

### Compact text projections

A list mode can provide `composml-root (buf)` and `composml-record (buf entry)`
without enabling the block renderer. The shared list publishes derived byte
ranges and stable record identifiers. LiveView groups its existing rendered
lines inside domain elements with `display: contents`. Dired uses `directory`
and `file`; ibuffer uses `buffers` and `buffer`; ichat uses
`chat-list` and `chat-entry`. Section headings remain headings. Text, faces,
line numbers, wrapping, and keyboard navigation use the existing text renderer.
These record wrappers establish identity. Column-level domain fields come from
`composml-fields` (see below), not from formatted text.

Preview boundaries use `c-preview` around the native iframe. Sandboxing, hooks,
and document rendering stay on the iframe. Minibuffer collections use `c-completions` and `c-completion`, with explicit
selection state. Imenu symbol candidates use `symbol-list` and `symbol-entry`.

All shared text-list modes default to `c-list mode="MODE"` and `c-item`
records. Domain callbacks specialize these names; modes need not copy the
rendering or CSS machinery. This covers the common lists while detailed domain
vocabularies can be introduced independently.

The concrete vocabulary and domain data contracts are listed in
[COMPOSML-COMPONENTS.md](COMPOSML-COMPONENTS.md). Text-list modes may supply
`composml-fields (buf entry)`: one semantic descriptor per displayed column.
The shared layout operation returns byte ranges for the fitted values, so each
field wraps its actual text and faces without rebuilding the table. Dired,
ibuffer and ichat use this contract. Agenda segments may supply a third value,
the semantic tag, after face and text. Imenu candidates carry name, kind, source,
line and documentation facts rather than requiring hint-text parsing.
