# WebAssembly

## Executable targets

- `wasm32` stores managed values in WebAssembly linear memory and exports `main` and `memory` by default.
- `wasm-gc` (also spelled `wasmgc`) uses the engine's WebAssembly GC. It exports `main` and only needs
  linear memory when native bindings require it.

Build either target from your project directory.

```sh
haxeon build --target wasm32
haxeon build --target wasm-gc
```

For an app with a `web/` runner, serve `build/web/wasm32/` or `build/web/wasm-gc/` over HTTP and open
its `index.html`. The Wasm GC bundle needs a browser with WebAssembly GC support. See
[Shipping](../guides/05-shipping.md#the-web) for the bundle layout and native package limits. For a standalone module, provide the imports it
requires and call its exported `main`. The [Haxe migration example](../coming-from/haxe.md) shows a module
run from Node.

Use `--build-mode release` to omit development patch metadata from a distributed build.
Both targets define `wasm` for conditional compilation. Wasm32 also defines `wasm32` and
Wasm GC defines `wasmgc`.

Both targets support objects and inheritance, enums, arrays, maps, iterators, closures, dynamic values,
strings, bytes and exceptions. Unsupported operations and native signatures produce a compile error.

String storage remains UTF-8 for ABI transfers. `String.length`, `charCodeAt`,
`charAt` and `substring` use UTF-16 coordinates on both targets, matching
HashLink. Substrings selecting a surrogate half retain it through WTF-8
storage. `haxe.io.Bytes` still counts bytes. The Wasm regular-expression engine
uses UTF-16 match positions and consumes whole Unicode scalars.

## Standard library on Wasm

Where HashLink calls a native runtime, the Wasm stdlib substitutes Haxe code
under `#if wasm`, shared by both targets:

- `sys.io.File`, `sys.io.AtomicFile`, `sys.FileSystem` and the `Sys` path
  operations use `runtime.MemoryFileSystem`, a session-only in-memory store
  that a host-backed store can later replace. Failures follow the HashLink
  runtime's booleans and error messages.
- `EReg` uses `runtime.Regex`, a backtracking engine for the common PCRE subset;
  unsupported syntax throws when the pattern is compiled.
- `Std.random` is a fixed-seed xorshift generator; `Reflect.compare` follows
  `hl_dyn_compare` for null, strings, numbers and booleans.
- `hl.Gc` controls are ignored and its counters read zero. `Sys.getEnv` returns
  null, `Sys.systemName` is `"Web"`, and `Sys.executablePath` is empty.

- Threads are single-threaded stand-ins in `sys.thread`. `Thread.create` runs its
  closure to completion before it returns, so the program sees the effects the
  thread would eventually have; `Tls` keeps a separate value for each such
  thread; `Mutex` has nothing to exclude. `Lock` counts releases, and a wait
  with nothing to consume cannot be satisfied by any other thread, so it times
  out at once or, without a timeout, throws instead of hanging. `Condition`
  behaves the same way: `signal` and `broadcast` do nothing, `timedWait` times
  out, and `wait` throws. A thread closure that waits on something the
  creating code does only afterwards therefore fails on Wasm.
- `Sys.exit` calls the host's `std.sys_exit`, which must unwind the guest.
  `haxeon-host.js` throws `HaxeonWasmHost.HaxeonExit` carrying the status; the
  guest's own `try`/`catch` never sees it.
- `Reflect.deleteField` on a compiled class or record resets the field to null
  (zero for numbers) and reports success, as HashLink does; only dynamic
  objects actually lose the field.

`sys.io.Process` and `Sys.command` remain unsupported.

## Host ABI

A Wasm guest and its host meet only at C-ABI functions: every import and
export argument is a Wasm32 C ABI scalar or an address in linear memory.
Neither backend's value layout crosses the boundary, so one host serves both
the wasm32 and wasm-gc targets.

- `HaxeonHost` declares the host services (`print`,
  `write_output`, `flush_output`, `date_now`, `date_timezone_offset`, `argument_count`, `argument`,
  `callback_create`, `callback_close`). The compiler registers it for Wasm targets; `trace`
  (which prints Haxe's `File.hx:line: message` lines), `Sys.print`, `Sys.stdout()`,
  `Sys.stderr()`, `Sys.args()` and `Date` use it.
  `write_output(text, error)` selects stdout with 0 or stderr with 1;
  `flush_output(error)` publishes an unterminated line on that stream.
  `Sys.args()` returns the strings the host passes (`haxeon-host.js`'s `args` option); on wasm-gc it is
  empty, since the strings would need linear memory.
- The scalar `std` (`sys_time`, `sys_exit`, …) and `haxeon_runtime` math
  imports remain.
- C functions bound through HXI follow the Wasm32 C ABI as clang and
  Emscripten implement it: a record holding a single scalar
  travels as that scalar, other records by address, a record result through
  a leading result address, and C floats as `f32`. Wasm32 passes addresses of
  its own data; Wasm GC uses scratch memory for supported transfers, including strings and byte slices.
- Native callbacks: each HXI callback type gets an `@:expose`d entry function
  taking a closure id and the C arguments. `haxeon.wasm.Callbacks` keeps the
  closures and asks the host for a function-table entry through
  `HaxeonHost.callback_create(entry, signature, id)`; the table entry forwards
  native calls to the entry with the id. A callback handle is that table
  index on both backends.
- Functions declared `@:keep` survive dead-code elimination; `@:expose`
  functions are also exported under their names.

`haxeon-host.js` is the host side for a guest that shares
memory with an Emscripten module: it checks the memory contracts, implements
the services above, and forwards the guest's other imports to the Emscripten
module's C exports. Its optional `print` and `printError` callbacks receive
stdout and stderr lines respectively; defaults are `console.log` and
`console.error`. The streams buffer separately, and `flush()` emits pending
text without requiring a newline.

### Host-owned memory

Both targets can share host-owned linear memory. Compare the guest's `haxeon.memory.contract` custom
section with the host's memory contract before calling the guest. The host memory must match the
module's sharing mode and limits. Shared memory can be used by native code such as pthreads or
AudioWorklets. Haxe code still runs on one thread.

### Runtime-neutral profile

The optional Wasm32 runtime-neutral profile is for hosts that meter execution without WebAssembly
exception handling. The host supplies `haxeon_host.fuel_charge: () -> i32` and returns 1 to
continue or 0 to stop execution. Instantiation runs the module's start function and needs a budget
of its own. Fuel exhaustion and uncaught guest exceptions trap at the host boundary. This profile is
a direct compiler option. The project CLI does not expose it.

## Limits

- `wasm64` is unsupported. Both targets reject HXI interfaces with 64-bit pointers.
- Wasm GC supports a smaller set of native signatures than Wasm32. It supports scalar C imports
  and copies HXI scalar out parameters and declared byte slices through guest memory. Other
  aggregate and raw-memory API forms can be rejected.
- File operations use in-memory storage. External processes and concurrent Haxe threads are unavailable.
