# Project manifest

A Haxeon project is the directory holding its manifest: `haxeon.toml`, which `haxeon create` writes, or `haxeon.json`, the
original format, which every command still reads. Both hold the same settings under the same names, so one schema describes
them: a TOML table is a JSON object, a TOML array a JSON array. A directory with both files is a usage error (exit status 2)
that names both; nothing says which one is the project.

`haxeon migrate` turns a project's `haxeon.json` into the `haxeon.toml` that says the same, checks that it reads back to the
same values, and removes the JSON file; `haxeon migrate --dry-run` prints the TOML and changes nothing. `haxeon.lock` stays as
it is, written by `haxeon install` and `haxeon update`.

## The TOML shape

Top-level settings come first, then a section (a `[table]`) for each group. Inside `[dependencies]`, each dependency is an
inline table, one per line:

```toml
version = 1
entry = "Main"
sourceRoots = ["src"]
target = "host"
defines = ["my_define"]
outputDir = "build"

[package]
name = "my-app"

[dependencies]
ui = "^0.3"
foo = { path = "../foo" }
widgets = { git = "https://example.org/widgets.git", rev = "v1.2.0" }
core = { registry = "local", version = "^1.0" }

[format]
indent = "spaces"
indentWidth = 2
lineWidth = 100

```

The same project in JSON:

```json
{
  "version": 1,
  "package": { "name": "my-app" },
  "entry": "Main",
  "sourceRoots": ["src"],
  "target": "host",
  "defines": ["my_define"],
  "outputDir": "build",
  "dependencies": {
    "foo": { "path": "../foo" },
    "ui": { "git": "https://example.org/ui.git", "rev": "v1.2.0" },
    "core": { "registry": "local", "version": "^1.0" }
  },
  "format": { "indent": "spaces", "indentWidth": 2, "lineWidth": 100 }
}
```

A nested group is a dotted section or an inline table, whichever reads better; both mean the same:

```toml
[native]
sources = ["native/foo.c"]
includeDirs = ["native/include"]

[native.cmake]          # or, under [native]: cmake = { source = "native", target = "foo" }
source = "native"
target = "foo"

[instrument]
minCallMicros = 1
haxe = { include = ["app.*"], exclude = ["app.debug.*"] }
boundary = { imports = "blocking", extra = ["kernel32.dll!Sleep"] }
```

TOML has no null. Where a JSON manifest writes `null` (`"entry": null`), the TOML one leaves the key out, which means the
same. Comments (`# ...`) are TOML's own; `haxeon add` keeps them when it adds a dependency.

## Settings

Paths are relative to the manifest's directory.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `version` | integer | `1` | The manifest format; only 1 exists. |
| `package.name` | string | the directory's name | The package's name, which dependencies use. |
| `package.version` | string | | The package's version; publishing writes it. |
| `package.friends` | array of strings | `[]` | Packages that may use this package's `internal` declarations as its own code does, such as its tests built as a project of their own. Only the package can name its friends. |
| `entry` | string | none | The entry module of a program; a library has none. |
| `sourceRoots` | array of strings | `["src"]` | Source directories. |
| `scopeSourceRoots` | boolean | `true` | A root holds only this package's modules. |
| `unscopedSourceRoots` | array of strings | `[]` | Roots (listed in `sourceRoots`) that may hold any package. |
| `sources` | array of strings | `[]` | Compile exactly these files instead of every file under the roots. |
| `workspace` | array of strings | `[]` | Member package directories ([Workspace](cli/build-run.md#workspace)). |
| `target` | string | `"host"` | `host`, `android`, `wasm32`, `wasm-gc` or `OS-ARCH`. |
| `defines` | array of strings | `[]` | Conditional compilation defines, `NAME` or `NAME=VALUE`. |
| `inline` | boolean | inlining on | `false` builds with `--no-inline`. |
| `nullSafety` | string | `"off"` | `"strict"`, `"loose"`, `"off"` or `"warn"`: the null-safety checker's mode for this package (below). |
| `outputDir` | string | `"build"` | Where builds go. |
| `dependencies.NAME` | string or table | | One dependency. A version range alone (`ui = "^0.3"`) is a release of the `haxeon` registry, the same as `{ registry = "haxeon", version = "^0.3" }`. A table names its source: `path`, `workspace`, `git` + `rev`, `registry` + `version`, or `haxelib` + `version`. |
| `patch.REGISTRY.NAME` | table | | `{ path = "DIR" }`: resolve the registry package `NAME` from a local directory instead, without changing the dependencies that name it, as Cargo's `[patch]` (`[patch.haxeon]` below). Only the root project's patches apply. |
| `native` | table | | C and C++ sources: `sources`, `includeDirs`, `std`, `targets`, or `cmake` (`source`, `target`, `inputs`, `library` or `libraries`). A CMake project finds those of the packages it depends on: in an app's graph their targets, otherwise their build directories in `CMAKE_PREFIX_PATH`, for `find_package` of a config each leaves there. |
| `ffi` | table | | `imports`, `interfaces`, `projections`: FFI recipes, interface files and their projection maps ([C_HEADER_FFI.md](C_HEADER_FFI.md)). `wasmInterfaces` replaces `interfaces` in a Wasm build. Each projection map names the interface it projects, so a build uses the maps of the interfaces it has, and a map of an interface no list declares is an error. |
| `app` | table | | Makes the project an app: `name` (the package's by default), `id` (reverse-domain, required), `version` (`1.0.0`), `icon` and `platforms` (at least one of `linux`, `windows`, `macos`, `android`, `web`, `ios`). A project without it is a program, which builds to a module the VM runs; an app builds through its runner projects ([Build](cli/build-run.md#build)). |
| `format` | table | tabs, 120 columns | `indent` (`"tabs"` or `"spaces"`), `indentWidth`, `lineWidth` ([Formatter](cli/test-quality.md#fmt)). |
| `compatibility` | table | | `haxeon` (a version range), `targets`, `runtimeAbi`, `nativeRequirements`, `features`. |
| `publish` | `false` or table | published whole | How the package is published into a registry: `false` keeps it out of the registry; `exclude` lists files and directories left out (tests, vendored code that does not build), where a `*` segment matches any one (`libs/*/tests`), `vendor` maps a path in the published package to a directory outside it that is copied in (`{ nativekit = "../../shared/nativekit" }`). |
| `instrument` | table | everything | What `--profile=instrument` probes ([PROFILING.md](PROFILING.md)). |

A dependency written as a source table can include `platforms = ["linux", "macos", "windows"]` to limit it to those builds.
The lockfile records dependencies for all platforms. Android takes its application ID and launcher label from `[app].id`
and `[app].name`.

### The `haxeon` registry

A dependency written as a version range alone (`ui = "^0.3"`) comes from the `haxeon` registry, which is part of Haxeon's SDK
(the `registry/` directory of a release, [RELEASES.md](RELEASES.md)): the first-party packages (`ui`, `platform`, `gpu`, `editor`, `audio`, `animation`,
`nativekit`, `agentkit`, ...), versioned with Haxeon. The SDK ships them unpacked. Packages the SDK's registry lacks come from the source cache's `haxeon` index.
The release CLI writes and checks each package's checksum in `haxeon.lock`. A locked version an upgrade removed is picked again within the range,
except with `haxeon install --locked`.

`[patch.haxeon]` points a package at a directory of your own, to change it without editing the dependencies that name it:

```toml
[dependencies]
ui = "^0.3"

[patch.haxeon]
ui = { path = "../ui" }
```

The directory's manifest must name the package as the dependency does (`ui`), as a published package's does.

### Null safety

`nullSafety` turns on the null-safety checker for the package's own code, in one of Haxe's modes: `"strict"` or `"loose"`
(`@:nullSafety(Strict)` and `@:nullSafety(Loose)`), or `"off"`, the default when the key is absent. `"warn"` checks as
`"strict"` does and reports what it finds as warnings, so a project can see what is left to fix while it migrates; any other
value is a manifest error. `haxeon create` writes `nullSafety = "strict"`, so a new project starts null safe.

Each package uses its own setting: the root project's applies to its sources, each dependency's to its sources, and a Haxelib
package without a Haxeon manifest is off. A package's setting reaches what its source roots hold: its package for a root that
holds only the package (`scopeSourceRoots`), and each top-level package and module of a root that may hold any. As in Haxe,
`@:nullSafety` metadata in the source applies on top of the setting: `@:nullSafety(Off)` turns the checker off for what it marks,
and `Loose` cannot lower what `Strict` covers. What the checker reports is in
[LANGUAGE_SUPPORT.md](LANGUAGE_SUPPORT.md#null-safety), "Null safety".

## How commands find the manifest

A command run in a directory uses that directory's manifest. `--project PATH` names a manifest file or a directory holding
one. A dependency's, a workspace member's and a tests project's (`tests/` beside the project, for `haxeon test`) manifest is
found the same way, so a TOML project can depend on a JSON package and the other way round. `haxeon fmt`, `haxeon lint` and the
language server walk up from a source file to the nearest directory with a manifest.

The TOML reader is the standard library's `toml.TomlParser` (TOML 1.0, errors with line and column), so a manifest error says
where: `Could not parse app/haxeon.toml: line 4, column 9: expected ] after the table name`.
