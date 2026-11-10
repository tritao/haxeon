# ADR 0003 section 13, step 2: helper requests as records, not callee names (design note, no code)

Status: proposal. Input: the provider table as it stands after the "Replace the hand-kept prefix lists" commit; dev-71's note that
the walk meets a *request* for a helper that does not exist yet.

## The situation

After step 1 every helper carries `Provides.Serves(TypeKey, operation)` and the passes that recognized helpers by name prefix read the
table. What still works by name is the *request*: code that needs a helper not yet made calls it by a name only the generator can
build, and the pass that makes the helper recognizes the call by that name and parses the suffix:

| Request | Who writes it | Who answers it | What the name carries |
| --- | --- | --- | --- |
| `$enum-dynamic-box:<sha(T)>`, `$enum-dynamic-view:<sha(T)>:<b64 T>` | `ConversionResolver` (typing), as a call | `IrEnumDynamicDispatch` makes the box/view/unbox/test functions and the equality dispatchers | the enum type, hashed or base64 |
| `$typed-interface:<I>:<method>:<sha(signature)>` | the call site of a typed interface method (`IrTypedInterfaceDispatch.dispatchName`) | `IrTypedInterfaceDispatch` makes the dispatcher and one entry per implementor | interface, method, signature hash |
| `$generic-erased:`, `$generic-type-test:`, `$generic-method-reference:` | typing (`GenericOwnerErasure`) | `GenericOwnerErasure.generate` | owner, operation, member |
| `__dynamic_equal` (a native name) | any dynamic comparison | `IrValueDynamicDispatch`, `IrEnumDynamicDispatch` | nothing: "some dynamic equality exists" |

For the walk (decision 4 of section 13: a reachable function may only call reachable functions or functions its pass creates) each of
these is an edge to a provider that is not in `program.functions`. As a call name it is opaque to the walk; if the walk is to keep a
provider alive only when its type is created *and* the operation is requested, the request has to be data the walk can read.

## Proposal: an explicit request record

A request is `(TypeKey, operation, detail)`, the same triple a provider row has, plus the call that will be rewritten:

```
typedef HelperRequest = { key:TypeKey, operation:ProviderOperation, detail:String }
```

Two ways to carry it, in order of preference:

1. **On the call.** `Call` keeps its callee string, but the callee becomes an *opaque handle* made by `IrHelperRequests.make(request)`
   that registers the record in a per-program `IrProgram.requests:Map<String, HelperRequest>` and returns the (still unique) callee
   name. The answering pass reads `program.requests` instead of parsing the name; it no longer needs `startsWith` or `substr`.
   Because the table is built when the call is built, the record survives snapshots exactly as `provides` does (it lives in the same
   persisted state). The name stays a name for backends and the debugger; nothing parses it.
2. **As a new instruction** (`RequestHelper(output, key, operation, args)`), replaced by a `Call` when answered. Cleaner for the IR but
   it touches every pass that matches on instructions and the codecs; defer to M2's pass framework, where instructions are being redone.

Option 1 changes only the producers (4 sites) and the answerers (3 passes) and keeps all other passes untouched.

## What the walk does with it

- An answerer is a *provider generator*: for each pending request in `program.requests` whose `key` is created (the type is created, or
  for dispatchers any implementor of the interface is created) it produces the provider row and function, and the request becomes an
  ordinary call edge to it.
- A request whose type is never created produces nothing; the call that carried it is unreachable by construction (its type has no
  values), so the walk drops it. That is the saving: today `IrEnumDynamicDispatch` builds a dispatcher over every enum helper whose
  name it finds, whether or not that enum is ever boxed.
- `__dynamic_equal` becomes a request with a *global* key (`TypeKey.dynamic`): "dynamic equality is used"; the dispatchers are then
  providers of that one request instead of passes that scan for the native name.

## Checks

- Check mode: every `Call` whose callee is a registered request handle is answered by the end of the pipeline, and no function
  named like a request handle exists without a record. This is the same shape as `IrProviders.check`.
- A request's `key` is a `TypeKey`, so a name-derived key does not compile (same guarantee as the rows).

## Order of work

1. `IrProgram.requests` and `IrHelperRequests.make`; convert the enum-box request (one producer, one answerer) and compare output.
2. Typed interface dispatch (the largest answerer), then generic erasure.
3. The `__dynamic_equal` global request; delete the native-name scans.
4. Only then the reachability walk reads `requests` and rows together (section 13 step 3).

Each step keeps the output byte-identical (app hldump identity plus both driver suites), as in step 1.

## Risks

- A handle that is a name still shows up in dumps; code that greps dumps for `$enum-dynamic-box:` keeps working.
- `program.requests` must be rebuilt when a pass rewrites calls (inlining copies bodies): the record is keyed by the callee name,
  which the copy keeps, so copies need no update; the check above catches a dropped record.
