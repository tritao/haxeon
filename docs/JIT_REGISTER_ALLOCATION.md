# HashLink JIT register allocation

## Baseline

The fork uses three stages: `hl_emit_function` creates SSA-like values, basic
blocks and phis; `hl_regs_function` assigns locations and emits physical-register
instructions; `hl_codegen_function` encodes machine instructions. `jit_emit.c`
and `jit_regs.c` are shared by x86-64 and AArch64. Register inventories and ABI
constraints come from `hl_jit_init_regs` in each backend.

Each `value_info` has one final location for its entire lifetime. `spill` assigns
`MK_STACK_REG(stack_pos)` and removes the value from the scratch/persist lists.
Because allocation finishes before physical instructions are emitted, an early
register assignment later spilled becomes a stack location even at its earlier
uses. `ADDRESS` forces this stable stack residence.

The scratch list holds caller-saved registers; the persist list holds callee-saved
registers. `regs_alloc_reg` first tries a preferred callee-saved register for a
value crossing calls, then a free persist register, then `steal_persist`. Stealing
compares weighted read counts and permanently spills the cheaper occupant.
Scratch-register pressure uses the next-use distance, with read weight breaking
ties. A fallback also tries unused callee-saved registers for other values.

`live_across_call` uses a prefix count of returning calls between the current
instruction and the final read. `M_NORET` calls do not increment it. At a returning
call, remaining live scratch occupants are permanently spilled; argument-register
conflicts can also spill values. SysV x86-64 has five available callee-saved GPRs
and no callee-saved floating registers. This explains why even a rarely executed
call can put a float in memory throughout a loop.

Liveness records uses and extends values needed in loops to their natural-loop
extent. The natural-loop walk in `jit_emit.c` follows predecessor edges from each
back-edge source to the header and takes the furthest member's end. Linear block
layout cannot identify the end correctly: inner-loop blocks can be placed after
the source of an outer back edge. `block_loop_depth` weights reads by eight per
nesting level, capped at seven levels. Debug assignments also extend tracked
value lifetimes through `regs_extend_debug_liveness`.

Tracked loop phis are explicitly stack-pinned by `regs_assign`, even in ordinary
builds that carry assignment metadata. That guarantees one stable debugger
location across incoming edges. Actual debugger mode is `jit->mod->debug`, set
by `--debug-port`, and must retain this guarantee under any optimization.

At a block header, phi allocation prefers a free incoming value's register.
`flush_phis` builds edge moves; `flush_movs` eliminates identical locations,
schedules moves whose destinations are no longer needed as sources, and resolves
cycles with exchanges. Conditional edges can use conditional moves/exchanges.
The same move scheduler also handles call arguments, which must **not** be
counted as phi moves in diagnostics. Ordinary binary/unary updates prefer their
left operand's register when it is free.

## Safety boundaries

Allocator changes must be enabled through backend configuration that only
x86-64 sets. AArch64 keeps the baseline behavior; it is not testable here.

Save-around-call allocation requires stores before argument shuffles and before
any collector entry, plus reloads after consuming the return value. The return
register can overlap a saved value. Address-taken values remain stack-resident.
Indirect call targets also require protection against argument-register shuffles.
A thrown exception skips the normal return/reload sequence; handler-visible values
must have authoritative stack homes or the function must use the baseline path.

Register tracking for try blocks assumes a register's recorded last value exists
on every path. Branch expansions that define one register separately on several
paths violate that assumption. No optimization may rely on such expansions.

A function's optimization may depend only on its bytecode and module metadata;
hot-patched functions cannot depend on another function's allocation history.

## Diagnostics

`HL_JIT_REGSTATS=1` writes process totals to stderr at normal exit.
`HL_JIT_REGSTATS=2` additionally writes one row per compiled function, identified
by bytecode function index and recorded function name. Counts include repeat
compilations from hot patches. They are observations, not allocator inputs.

Columns: pre-allocation emit instruction count, final stack-resident SSA values
(including phi values), final stack-resident loop phis, emitted phi move/exchange
instructions, and encoded code bytes including function padding. A phi exchange
counts as one emitted instruction. Call-argument moves are excluded. These static
counts are separate from retired instructions/cycles collected with `perf stat`.

## Measurement gate

The opt-in microbenchmarks live in `tests/bench/jit-regalloc`; they are not part of
the ordinary test catalog. Expected small-input results come from stock Haxe Eval.
A scratch prototype, rather than an inferred instruction count, establishes the
performance gap. The gate requires at least 10% lower runtime in nine alternating
pairs on a pinned core. Each accepted stage must also satisfy the full correctness,
benchmark, debug, GC, self-hosting and startup-cost gates.
