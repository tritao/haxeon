# WAMR runtime-neutral Wasm profile handoff

**Compiler branch:** `feat/wamr-profile-20261011`, based on
`8f018019d0b90f20cb9a98b9e5324d1d4f8cef70`.

**Ownership:** Compiler owns the opt-in Wasm lowering, driver flag, profile
identity and compiler regressions. Script owns the native WAMR host, AOT
build/run and memory limits. This compiler work has not passed Script's WAMR
AOT consumer gate and makes no AOT support claim.

## Contract confirmed with Script

Script's SR0 handoff and host harness establish these application imports:

| Module | Name | Wasm signature | Use |
|---|---|---|---|
| `haxeon_host` | `print` | `(i32) -> ()` | Existing output ABI |
| `std` | `sys_exit` | `(i32) -> ()` | Existing process exit ABI |
| `haxeon_host` | `fuel_charge` | `() -> i32` | New profile metering ABI |

The fuel host consumes one unit and returns `1`; it returns `0` on exhaustion
or interruption. The compiler traps with Wasm `unreachable` on zero, outside
Haxe exception dispatch. Script's host provides a separate initialization
budget because the Wasm start function runs during instantiation. Nested host
calls share the active invocation budget. The C heap and crypto runtime call a
module-local no-argument helper that uses the same host import.

The profile is explicitly selected with `--target=wasm32
--wasm-runtime-neutral`. The versioned `haxeon.runtime.profile` custom section
identifies linear memory, precise roots, `pending-global-v1` exception
propagation, metered startup and function-entry/loop-back-edge charges. The
opt-in profile retains `haxeon.gc.roots`, omits Wasm EH section 13, and does
not affect default `wasm32` or `wasm-gc` output.

## Compiler implementation and evidence

- Haxe throws set a pending flag and rooted dynamic payload. Calls check that
  state before using results; local handlers receive and clear it, while
  unhandled propagation returns to the caller and the exported boundary traps.
  Runtime bounds failures use the same pending state.
- The payload global is included in precise collector roots. The compiler
  regression throws an allocated object through a closure, catches and
  rethrows it, then retains it in an array while stress collection is enabled.
- Generated functions are charged at entry and structured loop back-edges.
  The linked heap and crypto functions are charged at entry; their C loops
  contain explicit calls through the module-local fuel helper.
- The Wasm backend driver regression also runs the SHA-256 C runtime through
  the profile and checks its result plus more than ten million accepted fuel
  charges, covering the linked crypto runtime and its long loops. A standalone
  Node run returned 42 after 13,253,565 charges.
- A generated start wrapper preserves the normal instantiation-time
  initializer and is itself charged. Export wrappers preserve results and
  trap on an unhandled Haxe exception.
- `scripts/test-wasm-backend.sh` has a profile CLI regression for the exact
  import signature, profile/root sections, EH absence, throw/catch/rethrow,
  fuel traps at entry/back-edge/start, and unchanged default profile
  selection. `tests/compiler/WasmBackendMain.hx` also compiles with GC stress.

The Haxe source grammar in this checkout has no `finally` construct. The
compiler fixture checks cleanup on both the normal and exceptional paths, but
that is not a `finally` language test. The current probe also does not exercise
a callback that re-enters Wasm through a host import. Those are explicit
semantic subgates; neither behavior is claimed by this handoff.

The two Script probes were compiled with the public compiler driver and run
under a local Node Wasm host with the agreed imports. Both called `std.sys_exit`
with 42; the runtime-neutral output had no tag section, retained precise-root
metadata and charged fuel during execution. `RuntimeNeutralProbe` used 3,079
charges; `AotSurfaceProbe` used 1,847,186. This checks compiler output and Wasm
semantics in Node only; it does not substitute for WAMR AOT.

The default `RuntimeNeutralProbe` output remains byte-for-byte equal to
Script's clean baseline artifact: SHA-256
`9e9252070ddb6cdcf604cd7920e11fceef88367df240a82838b553ee1e5ac026`.
The baseline has Wasm EH section 13, which the opted-in artifact removes.

## Paired Script repro contract

Use the same SR0 source, compiler arguments and pinned Haxe binary for both
builds. Set `COMPILER` to this checkpoint, `PROBES` to Script's
`libs/script/experiments/sr0`, and `HAXE` to the pinned Haxe 4.3.7 binary:

```sh
mkdir -p "$COMPILER/out/wamr-profile"

"$HAXE" --cwd "$COMPILER" -cp src --run compiler.tools.HaxeonCompiler \
  --target=wasm32 --output=out/wamr-profile/runtime-neutral-probe.default.wasm \
  --entry=RuntimeNeutralProbe --root="$PROBES" \
  "$PROBES/RuntimeNeutralProbe.hx"

"$HAXE" --cwd "$COMPILER" -cp src --run compiler.tools.HaxeonCompiler \
  --target=wasm32 --wasm-runtime-neutral \
  --output=out/wamr-profile/runtime-neutral-probe.neutral.wasm \
  --entry=RuntimeNeutralProbe --root="$PROBES" \
  "$PROBES/RuntimeNeutralProbe.hx"
```

Repeat the pair for `AotSurfaceProbe.hx`. Run Script's
`libs/script/experiments/sr0/run_haxeon_wamr_aot.sh` only against a clean
Compiler checkpoint. Script's gate must verify the imports and profile/root
sections, compile with pinned `wamrc-2.4.5`, and run with its configured
initialization budget, call budget and memory cap. Required probe outputs are
`sr0-runtime-neutral-probe-ok` and `sr0-aot-surface-probe-ok`, each exiting
with 42. That gate remains Script-owned and unrun for this branch.

## Remaining subgates

1. Run the exact Compiler self-host fixed-point gate and changed compiler
   integration tests on this branch.
2. Add a source-level `finally` test if/when the language supports it, and
   verify exception propagation through a host callback that re-enters Wasm
   before claiming those behaviors.
3. Hand Script a clean compiler checkpoint for its pinned WAMR AOT consumer
   gate. Do not infer AOT compatibility from disabled EH or Node execution.
