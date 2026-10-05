# IR opportunity census

Measured on the final post-inline IR with the defaults at `34a3582b` plus the corrected read-only census. Counts include emitted standard-library functions even when the benchmark does not call them. Each cell is static count / sum of `8^natural-loop-depth`. Recursion and caller loop frequency are not represented; these are opportunity counts, not a runtime profile.

| Benchmark | Reads | Writes | Counted | Reloads | Conversions | Allocations | Local allocs | Invariant computations | Const div/mod |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| binarytrees | 3/17 | 1/1 | 0/0 | 0/0 | 1/8 | 3/3 | 0/0 | 2/16 | 0/0 |
| merkletrees | 3/17 | 1/1 | 0/0 | 0/0 | 2/72 | 3/3 | 0/0 | 2/16 | 0/0 |
| fasta | 6/41 | 21/28 | 1/8 | 0/0 | 3/24 | 6/6 | 1/1 | 2/16 | 8/29 |
| nbody | 11/172 | 1/1 | 4/144 | 0/0 | 0/0 | 7/7 | 0/0 | 1/8 | 3/3 |
| spectral-norm | 7/161 | 4/25 | 0/0 | 0/0 | 4/256 | 6/20 | 0/0 | 3/24 | 0/0 |
| lru | 4/18 | 1/1 | 0/0 | 0/0 | 0/0 | 9/9 | 0/0 | 1/8 | 0/0 |

## Functions ranked by static weight

Ranks sum the weighted categories, which overlap. Standard-library support functions appear in the totals but are excluded here so unreachable `Sys.command` and `Sys.environment` do not obscure benchmark work.

| Benchmark | Function | Weight |
|---|---|---:|
| binarytrees | `App.main` | 17 |
| binarytrees | `App.make` | 2 |
| binarytrees | `Node.check` | 0 |
| binarytrees | `Node.new` | 0 |
| binarytrees | `Std.downcast` | 0 |
| merkletrees | `App.main` | 81 |
| merkletrees | `App.make` | 2 |
| merkletrees | `Node.calHash` | 0 |
| merkletrees | `Node.check` | 0 |
| merkletrees | `Node.new` | 0 |
| fasta | `Fasta.randomFasta` | 59 |
| fasta | `Fasta.new` | 21 |
| fasta | `Fasta.repeatFasta` | 18 |
| fasta | `Fasta.bisect` | 16 |
| fasta | `Fasta.makeCumulative` | 9 |
| nbody | `App.advance` | 144 |
| nbody | `App.energy` | 144 |
| nbody | `App.offsetMomentum` | 11 |
| nbody | `App.main` | 9 |
| nbody | `App.round` | 1 |
| spectral-norm | `App.eval_A_times_u` | 208 |
| spectral-norm | `App.eval_At_times_u` | 208 |
| spectral-norm | `App.main` | 43 |
| spectral-norm | `App.eval_AtA_times_u` | 1 |
| spectral-norm | `App.eval_A` | 0 |
| lru | `App.main` | 6 |
| lru | `LRU.put` | 2 |
| lru | `LRU.new` | 1 |
| lru | `LinkedList.add` | 1 |
| lru | `LCG.new` | 0 |

## Decisions and limitations

- **Stage 2: no-go for these benchmarks.** Nbody has no array writes in its benchmark functions. Fasta has one weighted array write in `randomFasta`, but it builds the character-code array once; the per-character write is `Bytes.set`, not `ArraySet`. The 19 constructor array writes are initialization. Fusing typed array writes therefore has no material hot-loop target in either required acceptance benchmark. Spectral-norm writes once per row, outside its quadratic inner loop. No fused-write implementation is retained.
- **Stage 3: go.** Nbody has four eligible reads, with weight 144 (two each in `advance` and `energy`); fasta has one in `bisect`, with weight 8. These are material hot-loop targets for the 3% gate. Spectral-norm uses numeric bounds, which require additional relations between its arguments and array lengths. The first census incorrectly returned zero because it expected a direct phi index and a guard in the same block as the phi. Actual `for` lowering starts the phi at `start - 1`, increments it in a separate guard block, then uses that incremented value. The corrected analysis recognizes this form, nested `i + 1` starts, and pure math calls by their actual native ABI binding. Tests use IR produced by the frontend, rather than an invented canonical form.
- **Stage 4: proceed to runtime profiling.** Both tree benchmarks recursively allocate and traverse objects; the loop-weight proxy systematically understates this work. GC and locality are the material candidate.
- The conversion category includes scalar int/float conversion as well as boxing and casts. Spectral-norm's 256 weight is arithmetic conversion, not dynamic boxing; it does not justify a boxing pass.
- Repeated loads are a conservative, block-local lower bound. Any store or unknown code execution clears the diagnostic table. Zero does not exclude opportunities requiring alias analysis or cross-block reasoning.
- Invariant computations counts only computations whose immediate inputs are constants or defined outside a natural loop. It does not count transitively invariant chains or field loads without an immutability proof.
- Allocations include `NewObject` and `__array_alloc_*` calls. Direct field/array-only uses qualify as local; casts, phis, calls, returns and publication reject them conservatively. Fasta's local allocation is a character-code array: the scalar replacement pass handles value-class objects, not arrays. Tree nodes escape via recursive returns and child fields; nbody bodies are published into an array, and LRU nodes into the cache. There is no supported value-class allocation left for scalar replacement.
- Constants, remainder and division counts are opportunities, not safety proofs. Fasta's RNG modulo dominates the constant-div/mod category. General reciprocal division is inexact; this census does not authorize that rewrite.

Enable with `HAXEON_IR_CENSUS=1`. Lines prefixed `IR_CENSUS` contain JSON arrays in the label order carried by the TOTAL line. The diagnostic runs after the final functions are published, including cache hits and `HAXEON_INLINE=0`; it does not affect fingerprints or mutate IR.

## Allocation explanations

Each per-function JSON row now carries an `allocations` array: output value ID, type, whether locality is proven,
and why scalar replacement leaves it in place. The first unsupported use is reported in instruction order; a call
or phi is a conservative failure to prove locality, rather than proof that the allocation escapes. The actual
per-compiler inlining choice is used when explaining disabled scalar replacement. All six totals and ranks above
remain unchanged, and every benchmark allocation has an explanation.

| Benchmark functions | Remaining allocations | Explanation |
|---|---|---|
| binarytrees / merkletrees `App.make` | Two `Node` sites each | Ordinary heap objects; returned from recursive construction. |
| fasta `Fasta.randomFasta` | Local character-code Int array | Arrays are outside the value-class scalar replacement pass. |
| fasta constructor / `makeCumulative` / `App.main` | Probability arrays and Fasta instance | Published in fields or passed to calls; ordinary arrays/objects are unsupported. |
| nbody `App.main` | Body records and their array | Passed to runtime array operations / dynamic conversion; ordinary objects and arrays. |
| spectral-norm `App.main` / `eval_AtA_times_u` | Float arrays | Passed to matrix-vector calls; arrays are not scalar-replacement candidates. |
| lru main / constructors / insertion | Generators, cache, list and nodes | Method calls, field publication or dynamic conversion; ordinary objects. |

`OpportunityCensusMain` checks these explanations, fresh constant fields, determinism and unchanged IR bytes.
The constant divisor category now tests actual finite powers of two, including subnormals and powers whose
reciprocal is not eligible for strength reduction. NaN, infinity and non-powers are not misclassified as powers.

## Follow-through

The material counted-loop reads justified an experiment, but its nine-pair timing gate failed: no benchmark
reached 3%, and fasta regressed consistently. The bounds pass was discarded; this census and its read-only proof
analysis remain. GC profiling likewise led to three independent experiments, none of which reached the 5% tree
gate. See [bounds results](BOUNDS_CHECK_ELIMINATION.md), [GC profile and results](GC_PROFILE.md), and the
[execution report](OPTIMIZATION_NEXT_RESULTS.md). Fused writes were never implemented because the census gate
provided no material hot-loop target in the required benchmarks.
