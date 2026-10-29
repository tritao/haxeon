# Live patching

Haxeon treats hot replacement as a transaction, not a best-effort reload:

- Every live module has a 128-bit identity.
- Functions receive persistent stable IDs independent of bytecode ordering.
- Patches carry an expected base revision and replacement revisions.
- Symbol tables are verified by prefix length and content hash.
- Patch call sites use stable-target relocations rather than stale bytecode
  function-table indices.
- All replacements are validated and JIT-compiled before publication.
- Multi-function patches become visible atomically.
- Failed staging is discarded without changing the live program.
- Stale, replayed, cross-module, and incompatible patches are rejected.

Calls and commits are synchronized. Permanent per-slot dispatch entries keep
existing closures and object prototypes valid, while superseded JIT code is
reclaimed after protected calls complete. Retained objects and closures pin
their owning module until released, and module disposal is idempotent.

Type-table growth remains a reload boundary because initialized HashLink modules
store direct `hl_type*` pointers. Haxeon fails closed for new function or
structural types until the runtime has a non-moving type arena.

## Artifact builds and live sessions

Live patching needs the compiler to keep its function slots, symbol-table indices, and stable function IDs
append-only across builds, so a patch can address the running module. That history has a cost for anything else:
a removed function keeps its slot, a replaced string constant stays in the table, and the bytes a build produces
depend on what the compiler session compiled before it.

So the history is opt-in. Without `--live`, every compile assembles from a fresh assembler and the module is a
function of the source alone: a warm session that compiled other revisions first produces the same bytes as a
cold one, with no dead functions or constants. Frontend caches (parsing, typing, IR) stay incremental either
way, and HL assembly is about a tenth of a compile, so nothing meaningful is lost.

- `haxeon run --watch --live` builds with `--live` for you.
- **A watch session keeps its compiler.** The worker whose session holds the patch history is chosen once, at
  the first build (`haxeon: compiler worker version <hash> (kept for this watch session)`), and every rebuild
  uses it. Edits to Haxeon's own compiler sources do not reach a running session, and nothing warns about
  it: **restart the session after changing the compiler.** A new worker could not patch the running module
  anyway, since it has none of the session's history.
- The compiler CLI accepts `--live` for `--target=hl`; the `Compiler` API keeps history by default
  (`Compiler.livePatching`), and `CompilerDriver` sets it from the request.
- The `<output>.hli` and `<output>.live.json` sidecars describe the session (module identity, revision), not
  the artifact, and still differ between sessions.
- `<output>.live.stamp` holds the publication key (`identity:revision`) and is published after `.live.json`. The live
  host reads it every tick and parses the description only when it changes; without a stamp it parses every tick.


## Unchanged publication

With publication tracking enabled, a live build whose assembled runtime state is unchanged returns
`CompileResult.unchanged = true`, retains its revision, and leaves no publication pending. The host must not
acknowledge or reject that result; either call reports that no publication is pending. Changed results still
require acknowledgement after publication, or rejection when staging fails. Enabling tracking after an
untracked build still requires an initial publication, even when its source has not changed.

`CompileResult.baseRevision` and the live manifest's `baseRevision` identify the baseline a patch expects.
The live host checks this against its running revision before invoking the patcher; skipped revisions and
legacy manifests without a base revision require a reload. An unchanged CLI build preserves the previous
patch, manifest, and stamp, so a host that has not polled yet can still consume that publication. For changed
builds, the CLI writes the publication stamp after the other artifacts and rolls compiler state back if staging
fails. Switching between artifact and live modes starts a new compiler session.

Each compiler request reads a source into one shared snapshot, including structural-change checks. Consecutive
reads must agree before the snapshot is cached, and a failed request cannot retain that cache for the next one.
Shape-lexer errors name the actual source file.
