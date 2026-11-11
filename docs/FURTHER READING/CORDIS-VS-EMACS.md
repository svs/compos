# Cordis, Lisp, and What JavaScript Has to Rebuild

> “Any sufficiently complicated C or Fortran program contains an ad hoc,
> informally-specified, bug-ridden, slow implementation of half of Common Lisp.”
>
> — Philip Greenspun’s Tenth Rule

DeepSeek Harness suggests a modern version of Greenspun’s rule. Everything in it is a plugin: model adapters, tools, persistence, telemetry, and the agent loop. Under the Harness sits Cordis, a framework built around what its authors call *spatiotemporal composability*. Cordis gives JavaScript properties that a Lisp runtime already provides.

Cordis and Lisp begin from different ideas about what a program is. A JavaScript application is usually a graph of modules assembled into a product. A Lisp program can remain a live image, open to inspection and change. Cordis must construct composition above its host language. Lisp gets much of the same power from symbols, evaluation, and runtime state.

Cordis gives packages a way to appear, disappear, and react to each other. However, copying the framework into a Lisp system would reproduce facilities that the runtime already supplies. The problem is smaller: resources such as processes and sockets need owners. Lisp uses explicit cleanup for those cases. A system built on OTP can use supervision.

## What spatiotemporal composability means

Most plugin frameworks handle spatial composition. They describe which components exist together. One plugin provides a service, another consumes it, and a registry maps names to implementations. Dependencies determine startup order. Configuration selects providers. The framework builds one working system from separate parts.

Cordis adds the temporal dimension. A component does not only occupy a place in a dependency graph. It enters and leaves a running system. During its lifetime it can register services, attach listeners, start timers, and change shared state. Temporal composability means the runtime can reverse those changes when the component leaves. Spatial composability means components can declare requirements and react when the surrounding context changes.

The [Cordis paper](https://github.com/cordiverse/paper) describes these dimensions as reversible effects and reactive coeffects. An effect changes a context and carries an inverse operation. The runtime records that inverse under the component that caused the change. A coeffect describes what the component needs from its context. When a provider appears or disappears, the runtime can activate, deactivate, or reconcile dependent components.

It establishes ownership across the framework. A plugin does not need to search global state during removal because the context already knows which effects belong to it. The model supports hot replacement and nested contexts without requiring one privileged application core.

## The JavaScript problem

JavaScript is dynamic, but a JavaScript application is not a Lisp image. ES modules form a file-based import graph. Bundlers transform that graph before execution. TypeScript adds a second description of the program, then erases it. Frameworks impose component lifecycles over objects, closures, and callbacks that do not carry lifecycle ownership themselves.

Changing a source file does not naturally change every use of its definitions. Old closures can retain old functions. Consumers can hold object references that no replacement process can discover. Module caches preserve evaluated state. A development server can replace a module, but the framework must define what replacement means for state, subscriptions, and every dependent module.

Hot module replacement exposes the amount of machinery involved. A tool detects the changed module, identifies an accepting boundary, runs disposal handlers, replaces exports, and asks dependents to reconcile. Application code must preserve the state that should survive and remove the state that should not. This engineering makes a running JavaScript program behave more like an image whose definitions remain open.

Plugin systems repeat the same work at application scale. They create registries because static imports cannot express runtime replacement. They create contexts because dependencies need dynamic scope. They create lifecycle objects because callbacks do not remember who registered them. They track effects because mutations do not identify their causes. Cordis unifies these solutions and gives them clear semantics.

Lisp starts from another position. A Lisp system reads forms into a running environment. A symbol provides a stable name whose function or value can change. Code can define a replacement while the program continues to run, and future symbolic calls reach that replacement. Source code, configuration, extension code, and interactive commands all use the same language and evaluator.

This indirection is essential. Cordis must attach identities and lifecycle relations to JavaScript values because references often point directly to values. Lisp programs can route behavior through symbols that remain stable while their definitions change. Loading is evaluation. Replacement is another definition. Introspection reads the same environment that execution uses. A Lisp runtime does not need a separate component loader merely to make named behavior replaceable.

## Lisp as a composable runtime

Lisp does not prescribe one plugin architecture. Common Lisp, Scheme, Clojure, and Emacs Lisp make different choices about namespaces, compilation, and images. They share a more important orientation: programs retain symbolic structure at runtime. Names remain available to the evaluator. Definitions can enter an existing environment. Code and configuration use the same data structures and language.

Symbols provide stable identities while definitions change. Dynamic variables add contextual values without threading parameters through every call. Lists and maps make dispatch tables inspectable. Generic functions, macros, reader extensions, and condition systems let programs extend behavior without waiting for a framework author to expose one component boundary.

Emacs is the clearest large-scale proof. A buffer does not receive behavior from one closed editor class. Its major mode supplies the primary interpretation. Minor modes add independent behavior. Keymaps compose by precedence. Buffer-local variables specialize global defaults. Hooks hold functions at lifecycle points. Advice changes named functions without changing their callers. These mechanisms are Emacs facilities, but Lisp makes their implementation ordinary and their state inspectable.

They compose in space and time. One buffer can combine a language mode, completion, diagnostics, formatting, project commands, and user hooks. Another can use a different combination. A user can then evaluate a new definition and change the editor immediately. The evaluator remains part of the product, so development, configuration, extension, and runtime administration use one continuous environment.

Emacs adds useful bookkeeping rather than a universal effect model. Its `load-history` records definitions created while a library loads. According to the [Emacs Lisp manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Unloading.html), `unload-feature` removes definitions, restores earlier definitions or autoloads, removes provided features, and cleans common registrations such as standard hooks.

Late binding makes cleanup cheaper in any symbolic design. A registry can store a symbol and resolve its definition when used. Removing the definition makes the target inert. Idempotent registration prevents repeated loading from creating duplicate calls. The runtime needs explicit inverses only for state that remains active without its named definition.

Symbols provide identities. Data structures expose control flow. Dynamic bindings provide context. Evaluation introduces or replaces behavior. Individual Lisp systems can add package histories, modules, namespaces, or images without turning every change into a framework-managed effect.

## Where Lisp does not remove the problem

The Lisp runtime cannot infer the inverse of every action. A package can open a network connection, start a process, create a timer, mutate a private table, or install a closure in an unusual registry. Removing its function definitions does not stop external activity. Cleanup forms and package-specific unload functions handle effects that symbolic replacement cannot remove.

This limitation establishes the correct boundary. In-memory definitions and ordinary symbolic registrations can use Lisp semantics. Live resources need explicit ownership. A process must stop, a socket must close, and a timer must cancel. These operations require domain knowledge, regardless of the extension language.

Cordis applies one ownership model to both categories. That uniformity benefits a JavaScript framework because the host runtime offers little help with either category. In Lisp, the same uniformity can become unnecessary ceremony. It forces simple definitions and hook entries through an effect abstraction even though symbolic replacement already makes them manageable.

The better design uses the smallest mechanism for each class of change. Let the Lisp environment own definitions, variables, hooks, modes, and commands. Require an explicit disposer for a resource whose lifetime extends beyond those definitions. Do not make an ordinary command registration look like a socket merely because both came from a plugin.

## Scheme on OTP

This distinction becomes especially clear in an editor built with Elixir and Scheme. Scheme supplies the open extension environment. It owns named commands, modes, hooks, keymaps, tools, and policy. Elixir owns processes, sockets, PTYs, schedulers, and operating-system interaction. The rule is simple: Elixir supplies mechanism, while Scheme decides policy.

Unloading a Scheme package can remove its definitions and catalog entries. Symbolic hook targets then become absent or inactive. Idempotent registration prevents duplicate behavior after a reload. Most extension code needs no inverse stack, component context, or reconciliation engine.

OTP handles the harder lifetimes. A process belongs to a supervisor. Links and monitors report failure. Stopping a supervisor terminates its children in a defined order. If a Scheme package starts a timer or process, one small bridge can associate that resource with the relevant supervisor or package scope. The runtime does not need to encode every Scheme definition as a reversible effect to gain reliable cleanup.

This architecture combines two mature strengths. Lisp provides live symbolic composition inside the application. OTP provides ownership and failure handling for concurrent activity. Cordis remains a useful description of the desired result, but it does not need to become the implementation.

It also suggests a practical design test. Before adding a lifecycle abstraction, ask whether late binding makes the registration harmless. Before adding a dependency reconciler, ask whether a symbol lookup or dynamic variable already expresses the dependency. Before adding a component loader, ask whether evaluating a file already loads the component. Use stronger ownership only when a real resource demands it.

## Cordis is the framework; Lisp is the runtime

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md) demonstrates that Cordis works. It composes ordered bundles and patches into a running agent. Plugins contribute services, events, and reversible effects to scoped contexts. Providers can change without editing a privileged core, and registrations unwind when their plugins unload. Within the JavaScript ecosystem, this is an impressive result.

From the Lisp perspective, however, it is less radical. A live Lisp environment already treats its application as unfinished. A user can define behavior, replace a function, alter a dispatch table, and inspect the result within the same running image. When the extension language is also the implementation language, the boundary between application author and user remains deliberately weak.

Harness makes every subsystem a plugin because JavaScript modules otherwise harden into an import graph. Lisp keeps subsystems replaceable because named definitions remain open. Cordis turns replacement into a framework protocol. Lisp makes replacement an ordinary property of evaluation.

This does not make the Cordis paper unimportant. Its vocabulary identifies two real dimensions that most plugin designs confuse. Its effect model gives JavaScript programmers a coherent way to reason about removal. Its coeffect model explains how components react to changing dependencies. The paper formalizes a valuable target.

The mistake would be to assume that every language needs the same machinery to reach that target. A Lisp system should first use the powers already present in its runtime. A symbol is a replaceable connection. A hook is inspectable data. A mode is scoped policy. Evaluation is loading. Introspection is part of execution rather than a separate administrative interface.

External resources remain the honest exception. They need owners in Common Lisp, Scheme, Emacs, Cordis, and JavaScript alike. Once OTP owns those resources, little remains for a general effect framework to solve. The ordinary plugin layer can stay small because Lisp has already made the program open.

The difference is architectural, not cosmetic. Cordis adds composition above JavaScript. Lisp exposes composition through its language and runtime environment. Cordis is an impressive answer to a JavaScript problem. Emacs is only the most visible proof that the deeper answer is the runtime.

## Sources

- [A Programming Paradigm for Spatiotemporal Composability](https://github.com/cordiverse/paper)
- [Cordis](https://github.com/cordiverse/cordis)
- [DeepSeek Harness architecture](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [GNU Emacs Lisp Reference Manual: Unloading](https://www.gnu.org/software/emacs/manual/html_node/elisp/Unloading.html)
- [GNU Emacs Lisp Reference Manual: Hooks](https://www.gnu.org/software/emacs/manual/html_node/elisp/Hooks.html)
