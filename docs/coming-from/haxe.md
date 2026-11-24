# Coming from Haxe, HashLink and Lime

Haxeon is an independent language and runtime built on Haxe. It compiles a growing subset of Haxe and is independent
of the Haxe Foundation. You can often move plain `.hx` modules unchanged. Check dependencies and output targets before
you move a whole app.

## Will your source compile?

Start with the [compatibility table](../reference/LANGUAGE_SUPPORT.md#compatibility-at-a-glance) and
[Not yet supported](../reference/LANGUAGE_SUPPORT.md#not-yet-supported). The standard library is a subset too.
Check uses of `sys` and platform-specific imports even if your program uses familiar language features.

If your source uses Haxe's null-safe access operator, `name?.toUpperCase() ?? "anonymous"` fails at the dot
with `error[E0002]: Expected expression`. Use an explicit check such as
`name == null ? "anonymous" : name.toUpperCase()`. The [null safety example](../learn/null-safety.md) shows the same
check as an early return.

## Macros and generated code

| Haxe feature | Haxeon |
|---|---|
| Expression macros | Unsupported. Move the behavior into ordinary code or generate the source before the build. |
| Build and auto-build macros | Unsupported. Supply the fields or methods the build would have generated as ordinary source. |
| Initialization macros | Unsupported except for the CLI's recognized `--macro nullSafety(...)` option. Use `nullSafety` in a manifest. |
| `haxe.macro` APIs | Haxeon has no macro execution environment. If you keep a Haxe generation step, compile its output as ordinary `.hx` and check it against the supported subset. |

[Haxe command lines](../reference/CLI.md#haxe-command-lines) · [Null safety](../reference/MANIFEST.md#null-safety)

## Build and dependency translation

| In Haxe, HashLink or Lime | In Haxeon |
|---|---|
| `.hxml`, `-cp src`, `-main Main` | Run `haxeon build.hxml` for supported flags, or put the source roots and entry in `haxeon.toml`. |
| `-D NAME[=VALUE]` and `#if NAME` | Keep `-D` in the Haxe-style CLI, or use manifest `defines` or `--define` in project commands. Check each branch for APIs available on its target. |
| `-lib NAME:VERSION` | Use the exact version from Haxeon's Haxelib source cache. In a manifest use a dependency entry with `haxelib` and `version`. |
| `haxelib dev`, a Git checkout or an unversioned `-lib` | Declare a Haxeon path, workspace or Git dependency with a revision. The global Haxelib installation is outside Haxeon's dependency resolution. |
| Lime XML or HXP, `lime test`, `openfl test` | Create a Haxeon project with its own runners. Translate dependency and build configuration, and port the window, lifecycle and assets to the APIs you choose. |
| `--js` and browser or Node APIs | Build a compatible program with `haxeon build --target wasm32` and supply a Wasm host. Port imports of `js.*` and any DOM integration. |
| `--cpp` and hxcpp | Desktop app release runners build native executables from generated C. Port `cpp.*` code and hxcpp bindings. Use the [C and C++ interop guide](../guides/04-calling-c-and-cpp.md) for headers Haxeon can import. |
| `--hl FILE.hl` and `hl FILE.hl` | Keep those steps with `haxeon` as the compiler and its bundled `hl` as the runner, or use `haxeon run` for the project. |

Place a pure-Haxe release in `~/.haxeon/cache/sources/haxelib/<name>/<version>` or put its archive in the downloads cache.
Haxeon translates its `haxelib.json` to a manifest. The adapter needs exact versions for dependencies. Package settings
such as `extraParams`, macros and HXML compiler settings require manual translation. The CLI documents the supported
flags and the cache layout. [CLI reference](../reference/CLI.md) · [Manifest reference](../reference/MANIFEST.md#settings)

## Libraries and frameworks by output

The checks below used Haxeon at `017a8f078` on Linux x86-64 and Node for Wasm32. A tested row covers the
operation named in its scope. Wasm GC is untested here.

| Library or framework | Host JIT | Native AOT | Wasm32 | Scope |
|---|---|---|---|---|
| `utest.Dispatcher`, upstream `2.0.0-alpha` at `a055e05e` | Tested | Tested | Tested | Add one `Int` handler and dispatch 7. This covers the dispatcher module. |
| Lime and OpenFL | Untested | Untested | Untested | Port or verify the Lime platform layer and runner before testing OpenFL content. |
| HaxeFlixel | Untested | Untested | Untested | Its OpenFL and Lime dependencies need to work on your chosen output. |
| Heaps with HashLink or HTML5 | Untested | Untested | Untested | Verify the renderer, shader tooling and native dependencies for your backend. |
| HaxeUI with OpenFL, HTML or another backend | Untested | Untested | Untested | Verify `haxeui-core` and the selected backend together. |

The existing framework build commands and target-specific outputs remain part of their own toolchains.
[OpenFL targets](https://www.openfl.org/learn/haxelib/docs/targets/) · [Lime docs](https://lime.openfl.org/docs/home/) · [HaxeFlixel installation](https://haxeflixel.com/documentation/install-haxeflixel/) · [Heaps installation](https://heaps.io/documentation/installation.html) · [HaxeUI backends](https://www.haxeui.org/api/guides/backends.html)

## What changes at runtime?

Haxeon's VM is a HashLink fork. The host still runs `.hl` bytecode in a JIT, and Haxeon supports typed
`@:hlNative` bindings. Use the bundled VM for Haxeon builds and verify the library and native signatures your program
loads. The fork adds support for live patches. A compatible patch retains existing objects and state. A module reload
recreates module state, with app state carried over through `saveState` and `restoreState` when the app provides them.
An edit to the native runner or a compiler upgrade requires restarting the corresponding session.
[HashLink bindings](../reference/LANGUAGE_SUPPORT.md#source-declared-hashlink-bindings) · [Live editing](../guides/02-live-editing.md) · [Live patching](../reference/LIVE_PATCHING.md)

For desktop app releases, the runner builds a native executable. A Wasm module needs an engine and a host that supplies
its imports. A browser UI runner and web packaging of app dependencies with C or C++ code are still missing from the
project CLI. [Build targets](../reference/CLI.md#targets-and-backends) · [Shipping](../guides/05-shipping.md) · [WebAssembly](../reference/WASM_BACKEND.md)

## Move a small program

Open the [example project](examples/haxe/) and run the commands from its directory. The program formats a duration.
It has no external dependencies or macros. Its only host call is `Sys.println`. The checked-in `build.hxml` sets
the class path and entry, enables the `verbose` define and builds `original.hl`.

With stock Haxe 4.3.7 and HashLink, run the original project.

```sh
haxe build.hxml
hl original.hl
```

Move `src/Duration.hx` first. The conversion is pure arithmetic and needs no port.

```haxe
class Duration {
	public static function toMilliseconds(seconds:Int):Int {
		return seconds * 1000;
	}
}
```

Keep `Main.main` as the entry. Its call to `Sys.println` is available on the outputs used below.

```haxe
class Main {
	static function main():Void {
		final milliseconds = Duration.toMilliseconds(3);
		#if verbose
		Sys.println("Duration:");
		#end
		Sys.println('$milliseconds ms');
	}
}
```

If you start with a JavaScript HXML instead, the first error comes from the target flag. For example, run
`haxeon -cp src -main Main -D verbose --js main.js`:

```text
  --js main.js: Haxeon generates HashLink (--hl FILE) only
```

For the existing HashLink HXML, `haxeon build.hxml` is enough to compile the program with Haxeon. To use project
commands, put the same entry, source root and define in `haxeon.toml`.

```toml
entry = "Main"
sourceRoots = ["src"]
defines = ["verbose"]
```

Check the program in the JIT.

```sh
haxeon build
haxeon run --quiet
```

Build Wasm32 and run it in Node. The example's `run-wasm.cjs` provides the module's print import and calls its
exported `main`.

```sh
haxeon build --target wasm32
node run-wasm.cjs
```

The project CLI builds native executables ahead of time for desktop apps with a runner.
This console project has no runner, so its native AOT build requires the direct compiler and
SDK CMake integration. See [Shipping](../guides/05-shipping.md#desktop-a-development-build-and-a-release-build)
for the desktop app release workflow.

The JIT and Wasm runs print the same two lines.

```text title="Output"
Duration:
3000 ms
```
