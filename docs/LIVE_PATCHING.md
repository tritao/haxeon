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
- The compiler CLI accepts `--live` for `--target=hl`; the `Compiler` API keeps history by default
  (`Compiler.livePatching`), and `CompilerDriver` sets it from the request.
- The `<output>.hli` and `<output>.live.json` sidecars describe the session (module identity, revision), not
  the artifact, and still differ between sessions.
