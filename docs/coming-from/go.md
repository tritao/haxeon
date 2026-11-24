# Coming from Go

You can keep small functions, loop over a collection's keys and values, and put cleanup next to resource acquisition.
In Go, a deferred call captures its arguments when you register it and runs when the function exits. In Haxeon,
`defer` runs when its enclosing block exits and reads the locals at that point. A `defer` inside a loop body
therefore runs on each iteration that reaches it. [Go spec](https://go.dev/ref/spec#Defer_statements) · [Scoped cleanup](../reference/SCOPED_CLEANUP.md)

An ordinary Haxeon interface requires a declaration such as `implements Named`. Some protocols, including iteration,
use structural matching. Haxeon has no language-level goroutines or channels. An API that returns a Go value and error
can be expressed as an enum with success and failure cases, or adapted to an API that throws exceptions.
[Types](../learn/types.md) · [Enums and pattern matching](../learn/enums-and-patterns.md) · [Iteration](../reference/ITERATION.md)

For an executable, a Haxeon desktop app's release runner compiles the generated C. The ordinary project build produces
bytecode by default, which runs in Haxeon's VM. Go source packages and `go.mod` are specific to the Go toolchain. You
can call a supported C interface with Haxeon's FFI. [Go module files](https://go.dev/doc/modules/gomod-ref) · [Build targets](../reference/cli/build-run.md#targets-and-backends) · [C and C++ interop](../guides/04-calling-c-and-cpp.md)

| In Go | In Haxeon |
|---|---|
| `go run .` | `haxeon run` builds and runs the project in the VM. |
| `go build` for deployment | For a desktop app, use its runner and `haxeon build --build-mode=release`. |
| `go.mod` | Use `haxeon.toml` for source roots, the entry point and dependencies. |
| `for i, v := range items` | Write `for (i => v in items)`. |
| `defer f(x)` | Write `defer f(x);` for block exit. Save `x` in a local first if you need its current value. |
| `v, ok := counts[key]` | Use `counts.get(key)` and check the `Null<T>` result, or use `counts.exists(key)` to test membership. |
| Implicit interface satisfaction | Declare `implements Interface` for a class. For iteration, provide the protocol methods. |
| A `struct` used as a map key | Declare a `struct` that implements `Hashable`. |

[Project manifest](../reference/MANIFEST.md) · [Value equality](../reference/STRUCTURAL_EQUALITY.md)
