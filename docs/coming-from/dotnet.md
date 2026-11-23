# Coming from .NET

Classes, interfaces, generics and inferred locals will look familiar if you write C#. You can use a JIT during development
and build an app ahead of time for distribution. Haxeon development builds run in a VM derived from HashLink. Desktop
release app builds generate C and compile it into an executable with the runtime linked in.
[.NET publishing](https://learn.microsoft.com/en-us/dotnet/core/deploying/) · [Shipping](../guides/05-shipping.md)

Haxeon source uses its own standard library and package model. It has no CLR assembly or NuGet compatibility, and there
is no direct counterpart to C#'s `async`/`await` and task model. Port application code to the APIs available on your target.
For native calls you can bring a supported C or C++ interface. For a desktop UI, use the `ui` package and its reactive
views. [C and C++ interop](../guides/04-calling-c-and-cpp.md) · [UI basics](../guides/03-ui-basics.md)

| In .NET or C# | In Haxeon |
|---|---|
| `dotnet run` | `haxeon run` builds and runs a project. `haxeon run --watch --live` can patch a running app. |
| `dotnet publish` with Native AOT | For desktop apps, `haxeon build --build-mode=release` with a platform runner and a C toolchain. |
| `.csproj` and `PackageReference` | `haxeon.toml` describes the project, entry point and dependencies. |
| `string?`, `int?` and `??` | `Null<String>`, `Null<Int>` and `??`. Strict package checks report invalid nullable uses as errors. |
| `foreach` | `for (item in collection)`, with `hasNext()` and `next()` as the iterator protocol. |
| `using` with `IDisposable` | `scoped var` calls `dispose()` on a type that implements `Disposable` when the block exits. |
| A value-equal `record struct` | A `struct` implementing `Equatable`, or `Hashable` if you also need it as a map key. |
| P/Invoke | Use supported declarations from a C or C++ header through Haxeon's FFI. |

[Classes, interfaces and structures](../learn/types.md) · [Cleanup](../learn/cleanup.md) · [C# nullable reference types](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/null-safety/nullable-reference-types)
