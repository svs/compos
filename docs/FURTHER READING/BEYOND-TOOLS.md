# Beyond Tools: Composable Operational Contexts for AI Harnesses

**Draft systems paper — August 2026**

## Abstract

AI harnesses usually describe an agent's abilities as a list of tools. This model is too small. A useful agent also acts within buffers, modes, projects, identities, permission rules, resource lifetimes, and human interaction surfaces. These elements jointly determine what an action means and whether it is allowed. We call their composition an **operational context**.

This paper presents an architecture for programmable operational contexts. A small Lisp interpreter expresses policy, while an actor runtime owns all effectful mechanisms. Policy code cannot access the operating system directly. Every file operation, process launch, network call, and editor-state mutation reaches a finite primitive boundary in the actor runtime. Contexts can therefore compose higher-level abilities without creating new paths around mediation.

We built a prototype as an Emacs-like editor and AI harness on the BEAM. Its policy layer contains 21,362 lines of Scheme and 362 literal command definitions. The Scheme interpreter contains 927 lines of Elixir. Buffers, processes, agents, MCP connections, and asynchronous tasks are supervised BEAM processes. Scheme defines commands, modes, hooks, tools, agent presentation, and permission policy. Buffer mutations carry provenance through the system.

The prototype shows that tool composition is a special case of context composition. It also reveals a necessary distinction. A mediated effect boundary does not by itself provide object-capability confinement. The current prototype uses one global Scheme environment and policy checks at effectful primitives. Strong confinement requires per-context capability environments, unforgeable principal attribution, and systematic revocation. We define that stronger model, show why composition preserves mediation under its assumptions, and give an implementation path from the prototype.

## 1. Introduction

Language models act through harnesses. A harness supplies prompts, model transport, tools, state, and permission dialogs. Current systems often treat the tool list as the main unit of authority. A tool has a name, a description, an input schema, and a handler. Protocols such as MCP standardize this useful interface [1].

A tool list does not describe the whole environment in which an agent acts. The same `replace` operation has different meaning in a scratch buffer, a checked-out worktree, and a generated production file. The same mail action has different authority in a personal inbox and a shared support queue. A shell tool limited by a working directory differs from one that inherits the daemon's full environment. A permission prompt that no person can see differs from one attached to an active conversation.

These differences are not tool metadata. They belong to the operational context. The context selects resources, binds identities, supplies views, chooses policies, owns lifetimes, and determines how a person can inspect or interrupt an action.

Many harnesses construct this context informally. They concatenate prompts, filter tool arrays, pass environment variables, and rely on handler code to respect conventions. General-purpose extension runtimes add further ambient authority. A JavaScript extension can bypass a harness API through `child_process`, `fs`, or a network library. Python offers equivalent paths. The harness can log calls through its library, but it cannot claim that every effect uses that library.

This paper studies a different arrangement. The extension language has no operating-system interface. It can produce effects only through host primitives. The host is an actor runtime that owns files, processes, network connections, clocks, buffers, and agents. Policy remains live and programmable, but mechanism stays below one monitored boundary.

Our contributions are:

1. We define the **operational context** as the authority-bearing unit of an AI harness.
2. We define context operations for restriction, extension, rebinding, nesting, packaging, and revocation.
3. We show a sufficient condition under which policy composition cannot add an unmediated effect path.
4. We describe a working BEAM and Scheme prototype with live editor and agent applications.
5. We separate architectural mediation from object-capability confinement and identify the remaining enforcement work.

The central claim is simple:

> A tool is not the fundamental unit of agent capability. The fundamental unit is a composed operational context whose effects remain mediated after user-level composition.

## 2. From Tool Lists to Operational Contexts

### 2.1 The tool model

MCP defines tools as model-controlled operations with names, descriptions, input schemas, and optional output schemas [1]. It also recommends access controls, input validation, timeouts, logging, and human confirmation for sensitive operations. These requirements sit outside the basic tool definition.

That separation is reasonable for a transport protocol. It is insufficient as the internal model of a harness. Consider a coding agent with these tools:

```text
read_file(path)
replace_text(path, old, new)
run_tests(command)
```

The list omits facts that decide the real authority:

- Which project root can `path` name?
- Does `path` identify disk state or a live unsaved buffer?
- Which worktree receives the change?
- Who owns the resulting mutation?
- Can `command` invoke a shell, or only a named test target?
- Which environment variables reach the process?
- Which person can approve a request?
- What happens when the conversation closes?
- Which state survives a daemon restart?

A system can add fields until each tool carries every answer. This duplicates context across tools and makes composition difficult. A better model makes tools members of a larger context.

### 2.2 Operational context

We model an operational context as:

\[
C = \langle q, V, K, \Pi, R, L, U \rangle
\]

where:

- \(q\) is the principal identity and provenance.
- \(V\) is a set of state views.
- \(K\) is a set of callable capabilities.
- \(\Pi\) is the policy applied at capability invocation.
- \(R\) is the resource scope.
- \(L\) is the lifetime and revocation scope.
- \(U\) is the human interaction surface.

A **state view** is not necessarily a copy. It can be a restricted reference to a live buffer, syntax tree, mailbox query, project, or conversation record. A view defines what the principal can observe and how names resolve.

A **callable capability** combines an operation with authority. A capability to replace text in buffer `b` is narrower than a generic replacement function plus the string name of `b`. The first form carries its scope. The second asks the callee to reconstruct scope from ambient state.

The **human interaction surface** is part of authority. It identifies where a person observes actions, receives permission requests, and interrupts work. A headless agent cannot safely depend on a confirmation dialog in a detached window. Its context needs a fail-closed deadline or another decision channel.

### 2.3 Tools, modes, and buffers as context projections

An editor makes the broader model visible. A buffer supplies state and a stable object identity. A mode supplies interpretation, commands, keymaps, hooks, and presentation. A tool exposes an operation to a model. A project supplies name resolution and resource scope. A chat supplies identity, history, permission posture, and a human surface.

These objects are not unrelated plugin types. Each contributes fields to an operational context.

A mode can add capabilities and change views. A buffer can restrict a generic operation to one object. A tool can project a capability through a transport schema. A package can instantiate the same composition for several projects. An agent can receive a nested context whose authority is a subset of its parent.

The unification matters because it removes translation layers. The same policy closure can serve an interactive command, a model tool, or a hook. Its effectful leaves still invoke the same monitored primitives.

## 3. Context Composition

### 3.1 Restriction

Restriction removes views, capabilities, resources, or policy outcomes:

\[
\operatorname{restrict}(C, f) = C' \quad\text{where}\quad Auth(C') \subseteq Auth(C)
\]

Examples include a read-only project view, one writable buffer, a mail search without send authority, or a test runner without arbitrary shell access.

Restriction should produce a new callable object. A caller should receive `edit_this_buffer`, not `replace_any_buffer` plus a prompt instruction about which name to use.

### 3.2 Extension

Extension adds an explicitly granted capability or view:

\[
\operatorname{extend}(C, g) = C \cup \{g\}
\]

The grant must come from a principal that already holds \(g\). A child cannot create authority through composition alone. This rule follows the capability model described by Miller, Yee, and Shapiro [2].

### 3.3 Rebinding

Rebinding preserves behavior while changing the resource that a name denotes. A generic code-review package can bind `project` to a disposable worktree. A mail triage package can bind `inbox` to a saved query. A writing mode can bind `preview` to a browser tab owned by its context.

Rebinding is safer than string substitution because the new binding can carry narrow authority. The package need not receive a global file primitive and a different root string.

### 3.4 Overlay and precedence

Contexts can overlay policy and presentation:

\[
C_1 \oplus C_2
\]

An overlay needs explicit conflict rules. Presentation can use ordered precedence, as editor keymaps do. Authority should normally use intersection or deny precedence. A local policy must not silently widen a parent context.

For example, a language mode can add structural navigation to a project context. A review mode can then replace write operations with patch proposals. The resulting context retains project scope and gains the stricter write policy.

### 3.5 Nesting

A nested context has a parent and a bounded lifetime:

\[
\operatorname{child}(C, S) = C_S \quad\text{with}\quad Auth(C_S) \subseteq Auth(C)
\]

An agent thread, sub-agent, worktree task, or permission dialog can own a child context. Closing the child revokes its wrappers and terminates its supervised resources. A child can delegate a further subset without involving a global registry.

### 3.6 Packaging

A context package is a function from explicit inputs to a context:

\[
P : Inputs \rightarrow C
\]

Inputs can include a buffer reference, project root capability, model, permission policy, and user surface. Packages remain ordinary policy code. They do not need authority while stored. They receive authority when a parent instantiates them.

This property supports fine-grained reuse. A package can produce a read-only research context, an editable review context, or a disposable execution context from the same policy definitions.

### 3.7 Revocation and lifetime

Pure definitions need no operating-system cleanup. Late-bound symbolic names can disappear or point to new definitions. External resources require explicit ownership. Processes, sockets, timers, and subscriptions must stop when their context ends.

This architecture assigns those resources to actor supervisors. Policy code selects when a resource should exist. The actor runtime owns its failure and termination behavior. OTP supervision trees provide this hierarchical process model [3].

Cordis calls the broader problem spatiotemporal composability. It models revertible effects and reactive coeffects for dynamic components [4]. Our model shares its concern for context change. We rely on Lisp late binding for ordinary definitions and on actor ownership for live resources. This split avoids treating every symbolic definition as an external resource.

## 4. Complete Mediation Under Composition

Saltzer and Schroeder define complete mediation as checking every access to every object for authority [5]. An AI harness needs a practical version of this principle. Policy code must not gain an effect path that bypasses the harness monitor.

Let \(E\) be the set of externally observable effects. Let \(P\) be the finite set of host primitives. Let \(M\) be the host reference monitor. We assume:

1. Policy code has no effect channel except calls to \(P\).
2. Every primitive \(p \in P\) reaches \(M\) before producing an effect in \(E\).
3. The principal and context supplied to \(M\) cannot be forged by policy code.
4. Policy code cannot introduce native code or a foreign runtime with ambient authority.
5. Resource references cannot name objects outside their granted scope.

Under these assumptions, policy-level function composition preserves mediation.

**Proposition 1: No composition bypass.** If functions \(f_1, \ldots, f_n\) can produce external effects only through \(P\), any closure composed from those functions can produce external effects only through \(P\).

The argument follows from evaluation structure. Pure language forms produce no member of \(E\). A composed call either evaluates another policy function or invokes a primitive. Recursive expansion therefore ends at a primitive for every external effect. The composition can change control flow and arguments, but it cannot introduce a new effect edge.

**Proposition 2: No authority amplification.** If every capability available to a child context is derived from a parent capability by restriction or explicit delegation, then policy composition cannot increase the child's authority.

This proposition requires more than a primitive allowlist. Capability references must carry scope, and principal attribution must be unforgeable. A global namespace containing generic file and shell primitives does not satisfy the premise, even when callers promise not to use them.

These propositions separate two properties that systems often conflate:

- **Mediation:** every effect crosses the host boundary.
- **Confinement:** a principal can reach only its delegated subset of that boundary.

The first property supports logging, provenance, and central policy. The second supports least authority. A robust harness needs both.

## 5. Prototype Architecture

We implemented the architecture in a working editor and AI harness. The prototype currently uses the name Compos. It rebuilds Emacs-like editor semantics on the BEAM and uses a small Scheme interpreter for policy.

The design rule is:

> Elixir supplies mechanism. Scheme decides policy.

### 5.1 BEAM mechanism layer

The BEAM layer owns operations that process bytes, cross an operating-system boundary, or require concurrent resource ownership. It includes:

- one GenServer for each buffer;
- supervised operating-system processes;
- supervised agent threads and model transports;
- MCP connections;
- file and network operations;
- tree-sitter and rope native code;
- frame, window, input, and persistence state;
- schedulers, timers, and asynchronous tasks.

The application uses dynamic supervisors for buffers, processes, agents, and MCP connections. It uses a task supervisor for asynchronous work. A failing agent backend does not own the editor's policy state.

### 5.2 Scheme policy layer

Scheme defines the behavior that a person experiences as the editor:

- commands and keymaps;
- major and minor mode behavior;
- hooks and completion sources;
- display rules and themes;
- chat and agent presentation;
- tool definitions and presets;
- permission policy;
- applications for files, mail, Git, projects, org documents, and MCP.

The interpreter is intentionally small. Scheme numbers, strings, booleans, and lists are BEAM terms. Symbols use string-bearing tuples instead of atoms. This choice prevents user code from exhausting the non-collected BEAM atom table. Host primitives are ordinary Elixir functions registered by name.

The policy layer can redefine commands while the editor runs. Scheme closures serve as hooks, completion functions, permission handlers, tool handlers, and asynchronous callbacks. The Session process owns the interpreter store and serializes its mutation.

### 5.3 Primitive boundary

Scheme has no native file, network, process, or shell library. The host registers every such operation. For example, Scheme file reads call an Elixir file primitive. Process creation calls a supervised process module. Shell execution calls an Elixir primitive that can inspect attribution before it starts `/bin/sh`.

This boundary differs from an SDK convention. A normal JavaScript or Python extension can ignore a harness SDK and call the operating system directly. Scheme code in the prototype has no alternative implementation path. New mechanism requires a new host primitive.

The same rule applies to external protocols. Scheme decides which MCP servers and tools belong to a context. Elixir owns transport and connection state. Scheme decides how an agent event appears in a buffer. Elixir owns ordered event delivery and backend process lifetime.

### 5.4 Provenance

Every buffer mutation includes a source. Sources distinguish user, editor, process, and agent activity. Change events carry this source to subscribers. Read-only behavior and automated reactions can therefore depend on origin.

Agent tool dispatch installs an edit author around the Scheme handler. Buffer edits made by that handler retain the agent identity. The reactor ignores agent-sourced changes when necessary to prevent feedback loops. Provenance is also available to presentation and audit features.

Provenance must survive composition. A high-level Scheme function can call ten lower-level editor operations. Those operations still observe the same host-held author during the dynamic extent of the call.

### 5.5 Permission convergence

The prototype supports two agent lanes. One lane uses an in-process model tool loop. The other drives an external agent through ACP. Both lanes consult one Scheme permission policy. Agent threads own pending permission state, deadlines, and responses.

The human interaction surface changes enforcement behavior. A visible chat can show a permission request and wait. A headless MCP proxy cannot show that request. The proxy therefore treats an `ask` decision as refusal. This is an example of the user surface changing the operational context without changing the tool handler.

### 5.6 Live image and persistence

The Session loads bundled Scheme files and optional user configuration. Evaluation is also the external control API. One request can perform a multi-step editor action without serializing each primitive call through a foreign runtime.

Buffers and frames survive daemon restarts. Non-file buffers persist content, point, and selected local state. Mode setup functions reconstruct runtime keys, overlays, and folds. This separates durable context identity from live resource reconstruction.

### 5.7 Implementation size

The August 2026 prototype contains:

- 21,362 lines of bundled Scheme policy;
- 927 lines across the Scheme interpreter modules;
- 362 literal `define-command` forms;
- 69 core test files and 6 interpreter test files.

The counts exclude generated commands and user configuration. They do not measure quality or security. They show that a small interpreter can support a substantial live policy layer.

## 6. Context Composition Examples

### 6.1 Scoped code editing

A coding context can bind these elements:

```text
principal       agent:review-17
views           syntax trees and live buffers in worktree W
capabilities    read, exact replace, run named test target
policy          ask before writes outside generated patches
resources       worktree W and its supervised test process
lifetime        one agent thread
surface         chat buffer *review-17*
```

The context does not grant a generic shell. A test capability captures one worktree and one command family. A replacement capability captures a set of live buffers. A sub-agent can receive only the read and query capabilities.

The agent can compose these operations into refactoring tools. Composition does not create a second filesystem path. Every mutation still reaches the buffer primitive, and every test still reaches the supervised process mechanism.

### 6.2 Mail triage

A mail context can bind a saved query as its state view. It can grant archive, mark, and draft capabilities while withholding send. A reply mode can add a draft buffer and a confirmation surface. Only an explicit extension adds the send capability.

This design avoids a broad mail tool with a string action field. The model cannot discover a hidden `send` verb because no callable capability for it exists in the triage context.

### 6.3 Research context

A research context can combine browser-reading capabilities, note buffers, and citation tools. It can omit trusted browser input, downloads, and shell execution. A writing mode can overlay formatting commands without changing browser authority.

The package can be rebound to a different group of buffers for each research question. Each instance receives separate provenance and lifetime.

### 6.4 Context as an agent handoff

A handoff should transfer more than conversation text. It can package the current views, selected resources, capability subset, permission posture, and durable buffer references. The receiver starts inside the same operational world with narrower authority where appropriate.

This representation makes handoff inspectable. A person can review the context package before starting the child agent. Tool schemas remain a derived projection for the chosen model transport.

## 7. What the Prototype Does Not Yet Prove

The prototype demonstrates one effect boundary. It does not yet implement the full confinement model from Section 4.

### 7.1 One global Scheme environment

All policy currently runs in one Scheme Session. The global environment contains generic primitives. Tools and packages select operations through registries and policy conventions. Effect metadata supports discovery and permission decisions, but it is not an unforgeable capability.

The stronger design needs per-context environments or first-class capability objects. An agent should receive a closure over one buffer, not a generic buffer primitive plus a checked string. Removing a name from tool discovery is not sufficient because Scheme evaluation remains reflective.

### 7.2 Forgeable attribution inside trusted policy

The prototype carries agent attribution through dynamic host state. Trusted Scheme helpers can set that attribution around callbacks. A security boundary must not let untrusted policy clear or replace its principal. Future contexts should bind the principal outside the policy namespace and pass it directly to the reference monitor.

### 7.3 Descriptive effect metadata

Public Scheme definitions declare domains and effects such as `read`, `write`, `destroy`, `execute`, `external`, and `spend`. These declarations improve catalog search and policy. They remain author-provided descriptions.

A confinement system must derive authority from capability possession. It can use effect metadata for review, but it cannot treat metadata as enforcement.

### 7.4 Primitive audit

Complete mediation reduces the trusted computing base to the interpreter, primitive implementations, attribution path, and native extensions. It does not make that base correct automatically. Each primitive needs an audit for:

- resource name validation;
- principal propagation;
- scope enforcement;
- failure behavior;
- reentrancy;
- callback lifetime;
- output and error leakage.

Native code also needs separate review because memory-unsafe failure can cross the language boundary.

### 7.5 Denial of service and covert channels

The Scheme evaluator runs synchronously in one Session process. A non-terminating policy computation can delay other policy calls. The current interpreter also needs careful environment garbage collection for long sessions.

Capability restriction does not remove covert channels through timing, shared buffer state, logs, or resource exhaustion. Context isolation needs quotas, timeouts, and possibly separate interpreter processes.

### 7.6 Shell mediation is not shell safety

The prototype starts shells only in the BEAM mechanism layer. This gives one place for attribution and policy. A granted shell remains a broad capability. Strong contexts should prefer structured operations and named process capabilities. Operating-system sandboxing remains useful as defense in depth.

## 8. Implementation Path to Strong Contexts

The prototype can reach the stronger model without replacing its policy language.

### 8.1 First-class capability values

The host should create opaque capability references. Scheme can call them but cannot inspect or forge their identity. Each reference binds:

```text
operation, principal, resource scope, policy, lifetime owner
```

A generic host primitive can invoke these references. Context construction then becomes the only place that receives broad mechanism bindings.

### 8.2 Per-context lexical environments

Each agent or package instance should receive a lexical environment containing only its pure library and delegated capabilities. Shared definitions can remain immutable or late-bound through explicit imports. User-owned trusted configuration can retain a broader administrative environment.

This change turns absence into enforcement. Code cannot call a shell primitive that its environment does not contain.

### 8.3 Host-owned principal

The Session call envelope should carry the principal. Nested policy calls can retain or narrow it, but they cannot replace it. Buffer mutations and process starts should read the principal from the call envelope rather than a mutable policy-visible binding.

### 8.4 Capability attenuation

Host combinators should create narrower capabilities:

```scheme
(buffer-editor-cap buffer '(read exact-replace))
(project-reader-cap root '("*.ex" "*.scm"))
(test-runner-cap worktree '("mix test" "bin/test"))
```

The examples show intent, not a proposed final API. The important property is that attenuation returns a new opaque reference with no widening operation.

### 8.5 Lifetime ownership and revocation

Each context instance should own a supervisor subtree or a resource owner process. Revocation marks its capabilities inactive before stopping children. Callbacks should resolve through revocable indirection rather than retaining raw authority after context closure.

### 8.6 Context manifests

A context manifest should describe its principal, visible resources, capability effects, lifetime, and human surface. The manifest is for review and transport. The runtime should derive it from actual capability values, not construct authority from the manifest alone.

## 9. Evaluation Plan

A complete evaluation should test expressiveness, mediation, confinement, failure isolation, and cost.

### 9.1 Expressiveness

We will classify existing policy applications by the context fields they use. The prototype already includes editor modes, chat, mail, Git, project worktrees, MCP, browser control, and writing workflows. The study should measure how many require new host primitives and how many use composition alone.

### 9.2 Mediation audit

We will enumerate all Scheme primitives and classify each as pure, internal state, file, process, network, clock, secret, or native. Tests will attempt to produce each external effect without the corresponding primitive. The audit must include recursive evaluation, callbacks, error paths, and restored state.

### 9.3 Confinement tests

Adversarial policy programs will attempt:

- path traversal outside a granted root;
- principal replacement;
- capability serialization and forgery;
- use after revocation;
- callback retention after context closure;
- shell construction through indirect names;
- authority recovery through reflection;
- cross-context buffer access.

These tests should fail because authority is absent, not because a deny-list recognizes known strings.

### 9.4 Composition tests

Property tests can generate nested restrictions, overlays, and rebindings. For each generated context, observed authority must remain a subset of the parent authority plus explicit grants. Revocation must invalidate every derived capability.

### 9.5 Runtime cost

We will measure primitive-call latency, context construction, callback dispatch, and memory growth. Comparisons should include direct Scheme calls, JSON-RPC tool calls, and a foreign-runtime sidecar. The expected advantage is not raw interpreter speed. It is avoiding serialization and lifecycle bridges for multi-step policy actions.

### 9.6 Human control

We will compare tool-list review with context-manifest review. Tasks will vary resource scope, write authority, and interaction surface while keeping tool names constant. The study will test whether participants identify the actual authority and choose suitable permission postures.

## 10. Related Work

### 10.1 Extensible editors and live Lisp systems

Emacs demonstrates that commands, keymaps, hooks, modes, and buffer-local state can form a live extension environment [6]. Symbolic late binding lets a new definition affect future calls without rebuilding the application.

Our work retains this live policy model but moves byte processing, external resources, and concurrent ownership into the BEAM. The division makes the extension language an effect-constrained policy layer rather than the whole operating environment.

### 10.2 Capability systems

Object-capability systems bind designation and authority in references. They support delegation and attenuation without relying only on global access control lists [2]. Our strong context model applies these principles to editor objects, model tools, and human interaction surfaces.

The current prototype is capability-oriented but not yet an object-capability system. Its global Scheme environment and descriptive effect metadata prevent that stronger claim.

### 10.3 Complete mediation

Saltzer and Schroeder's complete mediation principle requires an authority check for every access [5]. General-purpose extension runtimes make this hard inside an application because extension code can use ambient operating-system APIs. Our language boundary removes those APIs from policy code.

The result still depends on a correct primitive boundary. Operating-system sandboxing can protect against defects in that trusted base.

### 10.4 Actor systems and OTP

Actor systems isolate state and communicate through messages. OTP adds standard process behaviors and supervision trees [3]. We use these mechanisms for buffer ownership, agent lifetimes, external processes, and protocol connections.

Lisp late binding and OTP supervision solve different lifecycle problems. Lisp manages replaceable symbolic policy. OTP manages live concurrent resources. The architecture uses each at its natural boundary.

### 10.5 Spatiotemporal composability

The Cordis paper defines temporal composability through revertible effects and spatial composability through reactive coeffects [4]. It implements these ideas in a JavaScript framework with context tracking, component loading, and hot replacement.

Our work focuses on authority-bearing agent contexts. A live Lisp environment already provides symbolic replacement for many policy definitions. OTP owns the external resources that need explicit lifecycle control. We therefore use a smaller lifecycle mechanism while adding principal, authority, state view, and human surface to the context model.

### 10.6 Agent tool protocols

MCP separates tool discovery and invocation from model providers [1]. This standardization helps a context project its callable capabilities to a model. MCP also places access control, confirmation, and logging responsibilities on implementations.

Our proposal sits below that protocol boundary. A context selects and scopes capability objects. A transport adapter then renders the selected projection as MCP or provider-native tool schemas.

## 11. Discussion

### 11.1 Why a small Lisp

The important property is not parenthesized syntax. The policy language must be live, composable, capability-limited, and cheap to embed. Scheme supplies closures, symbolic names, quoted data, and a small reader. Its values map directly to BEAM terms.

A JavaScript or Python runtime would add another heap, scheduler, module system, garbage collector, and ambient I/O surface. Restricting those runtimes would remove much of their package compatibility. Allowing them would break the single effect boundary.

A different small interpreter could satisfy the same architecture. Scheme minimizes the implementation needed for a live symbolic system.

### 11.2 Why buffers belong in the security model

Buffers are not only presentation. They are durable state views with identity, local policy, provenance, and human visibility. An unsaved buffer may be the authoritative version of a file. A chat buffer can own a permission surface. A diff buffer can expose a proposal without granting direct mutation.

Treating buffers as context members makes these distinctions explicit. It also joins human review state with agent execution state.

### 11.3 Why shell access is a terminal capability

A shell collapses many structured capabilities into one parser and ambient environment. Mediation at shell launch still records that a shell started. It cannot cheaply recover the semantic authority of every program the shell can invoke.

Contexts should therefore prefer semantic capabilities. Shell access should be explicit, narrow, and protected by operating-system isolation where possible. The architecture guarantees where shell creation occurs. It does not make arbitrary shell commands safe.

### 11.4 Contexts as the harness API

An external agent API can expose context construction rather than a flat tool registry. A caller can request a project reader, a patch workspace, or a mail triage context. The harness returns a manifest and a scoped endpoint.

This design supports model independence. Provider-native tools, MCP, ACP, and interactive commands can project the same underlying capabilities. Permission and provenance remain properties of the context rather than each adapter.

## 12. Conclusion

AI harnesses need to compose operational worlds, not only tool arrays. Buffers, modes, projects, identities, policies, lifetimes, and human surfaces jointly determine an agent's real authority.

A small policy language over an actor runtime provides a clean implementation boundary. Policy can remain live and user-programmable. Every external effect still reaches a finite set of host primitives. Higher-level composition changes behavior without adding an unmediated path.

The working prototype validates the expressiveness of this division. More than twenty-one thousand lines of Scheme define a substantial editor and agent harness over a small interpreter. The BEAM owns concurrent and external mechanisms.

The prototype also clarifies the next step. Complete mediation at the language boundary is necessary but not sufficient for least authority. Strong operational contexts require opaque capabilities, host-owned principals, per-context environments, attenuation, and revocation.

With those additions, a harness can grant an agent a precisely constructed world. The agent can compose freely inside that world, while the runtime continues to mediate every effect.

## References

[1] Model Context Protocol. “Tools.” Specification, June 18, 2025.
<https://modelcontextprotocol.io/specification/2025-06-18/server/tools>

[2] Mark S. Miller, Ka-Ping Yee, and Jonathan S. Shapiro. “Capability Myths
Demolished.” Technical Report SRL2003-02, Johns Hopkins University, 2003.
<https://papers.agoric.com/papers/capability-myths-demolished/abstract/>

[3] Ericsson AB. “OTP Design Principles.” Erlang/OTP System Documentation.
<https://www.erlang.org/docs/27/system/design_principles.html>

[4] Cordiverse. “A Programming Paradigm for Spatiotemporal Composability.”
Preprint, August 13, 2026. <https://github.com/cordiverse/paper>

[5] Jerome H. Saltzer and Michael D. Schroeder. “The Protection of Information
in Computer Systems.” *Proceedings of the IEEE* 63, no. 9, 1975, pp.
1278–1308. <https://www.cs.virginia.edu/~evans/cs551/saltzer/>

[6] Free Software Foundation. “Emacs Lisp Reference Manual.”
<https://www.gnu.org/software/emacs/manual/html_node/elisp/>
