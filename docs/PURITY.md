# Purity contracts

Status: deferred design (2026-10-31), not implemented. Feature 5 in [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md).

Deferred in favour of a runtime check: [ADR 0002](adr/0002-reactive-ui-model.md) makes the state the UI depends on
signals and throws at any signal or `State` write inside a tracking scope (decision 9, stage 1). That reports the bad write
at its line, with no annotations, which is how Svelte 5, Compose, Vue and Solid handle the same problem; none of them uses
compile-time purity. This contract is heavier: it spreads to every closure type and interface on the path, needs
conditional purity for generic code, and still needs trust-me holes (`@:cache`, the harmless-effect allowlist). Revisit it
if the runtime checks leave real holes, for example verify failures caused by plain-field writes during builds.

Purity *inference* without annotations remains useful on its own for the optimizer (dead call removal, common
subexpressions, loop-invariant hoisting) and does not need this contract.

## Why

The UI's retention model assumes that a view's build only reads state and describes nodes. Every panel that was hard to
retain broke that assumption: the inspection camera disposed and recreated its viewport inside `build`, the BIM editor
wrote its width and asked for a refresh, machine control cancelled gestures, and the CNC panel scrolled to follow the
executing line. Verify mode found each of these indirectly, as a difference between a retained frame and a fresh
rebuild, often scenarios away from the cause (`packages/ui/docs/RETAINED_SUBTREES.md`). The fix was always the same:
move the write to an explicit update step.

Observed reads have the same assumption and a worse failure: `BuildContext.observeString(() -> …)` re-runs its getter
during cache checks, so a getter with a side effect runs it on every check.

`@:pure` makes the assumption a compile-time contract. A write in a build becomes an error at the line that writes, with a
message pointing at the explicit update step.

## Meaning

A `@:pure` function may read anything reachable. It may write only to:

1. its locals, and objects it allocated during the call (including objects allocated by pure functions it called);
2. the context parameters it declares as writable with `@:effect` (a build's `BuildContext`, which records state IDs and
   observed reads);
3. fields declared `@:cache` (below).

It may call only pure functions: annotated, or inferred pure. Creating a closure is pure whatever the closure does when
called; calling one is pure only if its type says so. This is what lets a build create event handlers that change state
later.

Throwing is allowed. Reading mutable state is allowed: purity here is about effects, not determinism.

```haxe
interface View {
	@:pure function build(@:effect context:BuildContext):RenderNode;
}
```

## Annotations

- **`@:pure` on a function or interface method.** An interface method's annotation applies to every implementation and
  override; an override cannot drop it.
- **`@:pure` in function types.** `@:pure () -> Null<String>` accepts only lambdas and function references that check as
  pure. A pure function type is assignable to the ordinary one, not the reverse.
  ```haxe
  function observeString(read:@:pure () -> Null<String>):Null<String>;
  ```
- **`@:effect` on a parameter of a pure function.** Writes through that parameter, and calls to its methods, are allowed.
  The parameter's own methods are checked in their own right; `@:effect` does not make them pure.
- **`@:cache` on a field.** A pure function may write it. The field promises that its contents depend only on values the
  function could read anyway, so caching cannot change a result. Lazily built caches such as `TextRoleStyle.cachedColor`,
  measured text widths and the CNC panel's displayed status strings use it. Misuse is a contract violation the compiler
  cannot see; review and verify mode catch it.
- **Externs and natives** are impure unless annotated `@:pure`. A short allowlist of harmless effects (logging, profiler
  spans and counters, allocation probes) counts as pure.

## Checking

- **Inference.** A function without an annotation is inferred pure when its body passes the rules, so most helpers need
  nothing. Inference runs on the typed AST after typing, per function, with summaries cached and invalidated with the
  module, like the IR. Recursive groups are solved together, optimistically.
- **Calls.** A direct call to a static or final method uses that method's summary. A virtual call uses the annotation of the
  method it resolves to in the static type, so overriding a pure method impurely is an error at the override. Calls
  through `Dynamic`, untyped closures and reflection are impure.
- **Writes.** Field writes, array writes, map mutations and calls to mutating standard library methods are checked
  against the allowed targets. "Allocated during the call" is tracked as a local fact on values: a value from `new`, an
  array literal, or a pure function's result that the summary marks as fresh.
- **Generic code.** `Array.map`, `filter`, iteration helpers and `Lambda` are pure when their callback is. The first
  version handles these with conditional annotations on a fixed set of standard library functions (pure if every
  function-typed argument is pure), rather than general effect polymorphism.
- **Diagnostics** name the write or call, the pure function, and the chain of calls that reached it:
  `E2040: build is @:pure but calls InspectionCameraPanel.dispose, which writes viewport (InspectionCameraPanel.hx:41)`.
  An inferred-impure helper reports why.

## Use in the UI

| Where | Contract |
|---|---|
| `View.build` and component setup | `@:pure` with `@:effect context` |
| `observeInt/Bool/String` getters, `Derived<T>` and bindings (ADR 0002) | `@:pure` function types |
| style resolution, `Structural` operations, text measurement keys | inferred pure; annotated where they are relied on |
| event handlers, `update()` steps, `Effect`s, commands | impure by design |

Verify mode stays. Purity catches writes; verify still catches reads that were not declared as dependencies and stale cache
keys, which purity cannot see.

## Rollout

1. **Inference and diagnostics as warnings**, with `View.build` and the `observe*` parameters annotated. Fix or annotate
   what it reports in `packages/ui` and the editor; each finding is either a real write to move into an update step or a
   cache to mark `@:cache`.
2. **Errors per package** once that package is clean (`packages/ui` first, then the editor).
3. **Standard library annotations** for the conditional generic functions and the harmless-effect allowlist.
4. **ADR 0002 types** (`Derived<T>`, bindings) are declared with pure function types from the start.

## Open questions

- **`@:effect` granularity.** Whole-parameter permission is simple; restricting a build to the `BuildContext` methods that
  record (state, observe, ids) and excluding ones that act (commands, refresh) would catch more. Start whole-parameter.
- **Freshness through containers.** An object stored in a freshly allocated array and read back is still fresh; tracking
  that precisely needs more than local facts. Start conservative.
- **Hot reload.** A method changing from pure to impure invalidates its callers' summaries, so it is a signature change for
  incremental compilation and live patching.
