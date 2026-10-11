# World support on current main: isolated source integration

This candidate combines current-main Haxeon
`dfe768382d2ef7feefb2ba5504c76ee8b92f0afd` with the supported World compiler
checkpoint `8cfc48c96557144553c4adef41c44bc842a50135`. Their common ancestor is
`99c62706acbc825efb7d2d0019502b36150957ab`. It is a source integration for
review, not a downgrade to the old compiler binary. Beartooth main captured
for the audio gate is `c23ae799f1725d923023bfb9e5ce845672dc9b77`; the package
candidate subsequently advances to `cb12bb9d7cd58d5afa7f8974d29683fb46d4a3bf`,
which adds the document prototype without changing compiler/runtime pins or
audio Haxe sources.

The integration retains main's headerless value-class handling and its
Array.pop/shift behavior, adds the Flat record lowering and descriptor facts
consumed by World, and preserves both build IDs and descriptor sidecars.
The Wasm instruction matcher retains main's pointer/memory instructions and
adds FloatToFloat handling. These were the three textual merge conflicts.
The source delta imports the existing struct/descriptor implementation; it
does not introduce another schema family or Resource trust implementation.

Main's `native/`, `packages/`, and runtime dependency gitlinks have no delta:

| Dependency | Exact commit |
| --- | --- |
| HashLink | `9c3c68c2e434c6a281a140a21582d00a3e223ef8` |
| libffi | `12ffd1f9dc56fcea79d2f742f424301ae668d663` |
| NativeKit | `c7afffef0c868695334076d75e103ce825b45a2d` |

## Supporting fixes

Eight source issues were exposed by compiling and testing the combined source, rather
than by relying on an old bootstrap artifact:

- Delete the unreachable return after the crypto import callback throws
  (`E1012`). The callback continues to reject unexpected imports.
- Add `ContentDigest.makeHex` using supported byte operations, and use it for
  compiler build IDs and the digest cache. This retains lowercase SHA-256
  identities without requiring unsupported `Bytes.toHex` (`E1007`) or a
  runtime ABI change. Known empty/abc vectors and emitted build IDs are checked.
- Contextually type the CompilerSession FFI interface/projection arrays as
  their immutable source typedefs. This preserves dependency ordering and
  resolves the mutable/inferred record mismatch (`E1009`) without casts.
- Include binary/JSON descriptors in main's compiler-worker staging,
  publication and cleanup list. Previously successful worker builds left the
  descriptors at temporary names, so the build rejected missing outputs.
  Missing-sidecar rebuild and requester-cancellation tests cover publication,
  preservation of previous descriptors and removal of temporary files.

- Declare FFI projection directories as explicit directory outputs. File outputs
  remain strict; a directory cannot satisfy a compiler/library file output.
  Output kinds participate in action fingerprints and directory outputs remain
  excluded from the portable file artifact cache. The build-system regression
  checks missing/wrong kinds, valid directory execution/skipping and malformed
  declarations. This closes the main-era file-only validator / FFI-provider
  contract mismatch without weakening all action output checks.

- Limit the embedded compiler package's explicit source manifest to the
  compiler/runtime API seeds, with remaining APIs loaded on demand. Its
  previous whole-src manifest also loaded the compiler CLI `Main`, silently
  replacing an unscoped host `Main`. The aggregate's apparent stdlib-root
  failure was the wrong entry program executing, not a guest stdlib lookup.
  The unchanged host/guest/threaded incremental fixture passes after the
  manifest fix; an additional input-manifest assertion rejects CLI Main and
  requires the host entry. No ambient cwd change or constructor behavior
  bypass is used.

- Treat an inline-record field read as an allocation safepoint using the actual
  IR native-field layout. Constructing its owning view can collect a live
  destination copy before the next call. The pre-fix Wasm32 nested escape
  fixture returned 5 (diagnostic tag failure 51), and the minimal forced-GC
  fixture trapped. Both now return 42. SSA-root tests require source/copy roots
  at the inline read and exclude scalar reads; a permanent forced-GC fixture
  runs in parity. Ordinary field reads retain their existing behavior.

- Route files to the struct formatter using module-level lexical declarations,
  not a regular expression over raw source. The old routing matched a struct
  inside an embedded HXI string and corrupted a host map-comprehension arrow.
  The original host fixture is restored and retains its host formatter. Tests
  cover real declarations, strings, comments, regex literals and nested string
  interpolation, plus both numeric-storage/reload executions (42). This repairs
  the routing contract without expanding the compiler's source grammar.

The parity contract now explicitly requires scratch linear memory for the
C-crypto sha256 profile while continuing to require GC-managed representation
and no custom root section. Other GC programs still reject undeclared memory;
sha256 still executes its vectors. The obsolete ObjectMap removal skip is
removed because both targets pass. Both policy failures were reproduced on
unaltered main; nested-value collection was a real integration regression.

The twelve main-era formatting failures and four imported formatting failures
are corrected without semantic changes. The complete formatter (including the
struct-aware formatter) passes rather than skipping repository formatting.

Host bootstrap compiles 499 sources and converges after two self-host stages;
`bootstrap-compiler.sh --self` rebuilds the checked artifact identically.
The artifact SHA-256 is
`25c3dfc298b570cb6196e291d6a32ca763de5f2c23a7ea0a90655a4d8ffd78ac`;
its function map SHA-256 is
`f19eedc94e15fc430a7ee37c1f124cd19cb7a05210119aeffde4a498ce121d2b`.

## Consumer evidence

Reference-hosted source and explicit `--self-hosted` runs both pass the eight
paired gates: World (53 sources/full runtime), wide integer descriptors
(53 sources; defaults, full-width range, codec and snapshot registry),
Array.pop/shift value classes, score tests, level audio, playground smoke,
editor rendering (81 presets), and song selection/retirement.
Eight emitted build-ID sidecars also match their exact artifact SHA-256.

The audio inputs are captured from committed main plus its copied
FORMAT-RESEARCH notes at snapshot time. Ten candidate manifest paths are
adjusted locally to address packages relative to the Haxeon-root scratch;
the recorded adjustment list is authoritative. Later user edits to root
audio/DspEvent/NativeKit remain untouched and are not covered by these gates.

The isolated package candidate is based on exact Beartooth main with only
the committed `libs/world/` tree added. Both its World and integer consumers
pass using this compiler with explicit `--self-hosted`; its Haxeon gitlink
remains at main's dfe7683. This is the package/dependency integration boundary
to review before adopting the support compiler or merging locally.
The new committed-main document consumer also passes (34 sources).

## Full compiler acceptance

The final unskipped `scripts/test.sh` exits 0: 540/540 driver cases, every
integration stage (including embedding, worker descriptors and FFI directory
outputs), and 367 Wasm/HL parity fixtures pass, with 15 documented parity
skips. The permanent nested-value forced-GC regression also passes. Formatting
checks 1079 host files and 13 struct files (1092 total). The two numeric-storage
routing regressions pass independently (2/2) as well as in the full aggregate.

Environment limitations remain explicit: Python msgpack is unavailable (Haxe
canonical vectors pass); linear-runtime.wasm freshness is skipped without a
wasm32-capable clang; Wasmtime 47.0.0 is unavailable. These checks are not
represented as passing. All other configured stages finish in the aggregate;
there is no inherited aggregate-embedding waiver.

Final source/self consumer runs are sequential because their project outputs
are shared within this one scratch checkout. Earlier overlapping attempts are
retained as diagnostic logs and are not acceptance evidence. Final result
files `source-consumer-results.tsv` and `self-consumer-results.tsv` each contain
eight zero exits; `package-final-results.tsv` contains three zero exits.
Bootstrap logs are `bootstrap-final-host.log` / `bootstrap-final-self.log`;
aggregate log is `compiler-routed-complete-acceptance.log`.

## Remaining limits and evidence

World W1/SC1 remain partial. Integer snapshot APIs remain opt-in and
registry-bound; static native restoration, unrestricted rich cloning and
allocator-fault coverage remain outside the accepted profile. Resource
source/interface facts do not establish loader-bound proof. The short churn
is 256 warm-up plus 3 x 4096 cycles and is not the E4 soak.

Raw logs, source hashes and runners are task-local under ignored World
`libs/world/build/world-source-forwardport-dfe7683-20261011/build/`.
Repository formatting passes across all source/test/benchmark files, including
the struct-aware check. No World/root pin, root source,
carried plans, remote branch or immutable toolchain was changed.
