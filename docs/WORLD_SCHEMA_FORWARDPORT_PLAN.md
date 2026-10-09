# World descriptor/schema forward-port plan

## Consumer evidence

The target is the isolated accepted-main review branch at source checkpoint
`aee78ba4d9b2d5f330132447e7ef51cda994faf5`, with review/handoff commits through
`8f5856ab372f5f44282bfa3e9b562bc49e4ba21d`. Its runtime gitlink is HashLink
`0e739431da931d8e21c98c485afb17f1f3164106`.

The exact World-owned reproducer was copied to
`out/repros/world-descriptor-schema-current/`; its manifest output directory
was changed to local `build/`. On the unmodified review checkpoint, this
command fails as reported:

```sh
HAXEON_COMPILER_SESSION_DIR="$PWD/out/sessions/world-schema-baseline" \
HAXEON_SOURCE_CACHE="$PWD/out/cache/world-schema-baseline" \
HAXEON_DISABLE_ARTIFACT_CACHE=1 HAXEON_COMPILER_SERVER=0 HAXEON_CCACHE=0 \
TMPDIR="$PWD/out/tmp" scripts/haxeon build \
  --project="$PWD/out/repros/world-descriptor-schema-current/haxeon.json"
```

Observed diagnostic:

```text
Main.hx:1:1: E2001: Missing module "haxeon.wire.MessagePackSchema"
```

World commit `a6e111460e92b9c81651609b930d11f7a69f2178` requires more than the
missing import. Its `DescriptorConsumerTests` and `WorldSchemaTests` exercise:

- Static `typeInfo<T>()` on ordinary Flat roots, nested Flat scalar records,
  nullable fields, and rich roots, including generic helper calls.
- Matching static and emitted descriptor identity/hash, schema version 4,
  flat/portable/layout facts, field type trees, annotation values, and
  recursive defaults.
- `MessagePackSchema.fromJson`, `requireDescriptor`, and
  `fieldDefaultValue(hash, type, path)` over format-version-3 sidecars. Tests
  distinguish no initializer, zero, explicit null, and nested values, and
  reject malformed hashes, versions, types, and unsupported executable or
  collection defaults.
- Named typed annotation arguments (`@:ReplicationOptions(group = 3,
  mode = "owner")`) and bounded `UInt8 = 250` / `Int16 = -1234` defaults.

The runtime schema class is self-contained over `MessagePackError`, JSON,
reflection, SHA-256, and `Bytes`; World does not call `MessagePack` by-name
codec or migration APIs. The World consumer gate disables artifact caching, so
module-granular persistent descriptor-cache support is outside this consumer's
required port. It will remain excluded unless a full consumer run demonstrates
that it is needed.

## Minimal source dependency set

The source history on the compiler lane is not a safe cherry-pick unit for this
accepted-main branch. The focused port will take only the behavior and tests
needed for the current World contract:

| Compiler-lane source | Required behavior in this port |
| --- | --- |
| `a5243380` | Recursive descriptor nodes for nested and non-flat field types. |
| `cb35d066` | Semantic dependencies that invalidate `typeInfo` callers when imported layout/schema facts change. |
| `6670fc0c` | Versioned JSON/binary descriptor sidecars and their deterministic writer. |
| `0b48ea4d`, `36cb5b8d` | Typed annotation descriptor values, canonical named arguments, annotation defaults. |
| `5d9bc584` | Generic `typeInfo<T>()` module dependencies and a nested generic regression. |
| `58ee77c1` | Ordinary Flat struct roots and supported explicit field-default metadata. |
| `0c45aa6d` | One consistent `size`/`alignment` field type across mixed Flat/rich roots. |
| `cc50ef32` | Range-checked fixed-width native scalar defaults in descriptor hashes/artifacts. |
| `18903233` + `860e9f2c` | `MessagePackSchema` runtime validation of descriptor format/version and bounded narrow defaults. Only the schema module/API and relevant validator tests are needed from the codec commits. |

The supported default profile remains constant scalar literals (including
explicit null) with absent metadata distinguished from a present value;
executable and collection initializers stay rejected. `MessagePackSchema`
validates format version 3 and descriptor version 4. The earlier migrations,
codec generation, and generic descriptor artifact cache commits
(`0b173014`, `a7a18fe3`, `aa7b9ee3`, `1c52f932`, `f753bbd1`) are not required
by any call in the current World consumer source and will not be imported as a
roadmap bundle.

## Conflict audit and port strategy

A no-commit cherry-pick audit applied each candidate independently to
`8f5856ab` in a disposable worktree at
`out/world-schema-conflict-audit/`; it did not change this branch. Generated
bootstrap conflicts occurred for each compiler-lane commit and will be
resolved by regenerating after the source set is stable. The accepted-main
branch removed lane progress docs, so `docs/STRUCTS_PROGRESS.md` appeared as a
modify/delete conflict and will be excluded.

The substantive accepted-main overlaps are in `ExpressionTyper.hx`,
`NativeTypeDescriptor.hx`, `NativeTypeDescriptorCodec.hx`, and
`NativeLayoutMain.hx`; their current branch versions include World layout and
`typeInfo` fixes that must be retained while transplanting the richer
descriptor profile. Annotation commits additionally overlap
`ModuleChangeAnalyzer.hx`. Artifact/default gates overlap `scripts/test.sh`,
`tests/compiler/NativeLayoutMain.hx`, and the expected-exit manifest; those
will receive explicit test registrations instead of accepting lane copies.
The generic dependency patch touches `DependencyScanner.hx` and
`ModuleAnalyzer.hx` without textual conflict on the current checkpoint, but
will be reviewed for accepted-main behavior and exercised with the World
generic helpers.

The direct audit also produced delete/modify entries for files whose
introducing commits were intentionally tested separately: descriptor codec
and artifact tests (before `6670fc0c`), typed annotation tests (before
`0b48ea4d`), and `MessagePackSchema` plus its reader/writer fixtures (before
`18903233`). The by-name codec source overlaps (`CallResolver.hx`,
`WireCodecGenerator.hx`, `MessagePack.hx`) are excluded; this World consumer
only needs the descriptor schema API. The machine-readable audit log is in
ignored `out/gates/world-schema-cherry-pick-audit.log`.

Implementation will proceed in bounded slices: descriptor tree/typeInfo and
static tests; artifact/default/annotation metadata and invalidation tests;
runtime schema API and schema tests; then the exact minimal repro and a local
copy of the full World consumer suite. Rebuild the checked-in bootstrap and
run the relevant driver, parity, bootstrap/self-host gates at the resulting
source checkpoint. No World or root pins will be changed.
