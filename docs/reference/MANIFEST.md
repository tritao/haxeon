# Project manifest

A Haxeon project is the directory holding its manifest: `haxeon.toml`, which `haxeon init` writes, or `haxeon.json`, the
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

[android]
applicationId = "org.example.game"
label = "Game"
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
  "format": { "indent": "spaces", "indentWidth": 2, "lineWidth": 100 },
  "android": { "applicationId": "org.example.game", "label": "Game" }
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
| `entry` | string | none | The entry module of a program; a library has none. |
| `sourceRoots` | array of strings | `["src"]` | Source directories. |
| `scopeSourceRoots` | boolean | `true` | A root holds only this package's modules. |
| `unscopedSourceRoots` | array of strings | `[]` | Roots (listed in `sourceRoots`) that may hold any package. |
| `sources` | array of strings | `[]` | Compile exactly these files instead of every file under the roots. |
| `workspace` | array of strings | `[]` | Member package directories ([CLI.md](CLI.md)). |
| `target` | string | `"host"` | `host`, `android`, `wasm32` or `OS-ARCH`. |
| `defines` | array of strings | `[]` | Conditional compilation defines, `NAME` or `NAME=VALUE`. |
| `inline` | boolean | inlining on | `false` builds with `--no-inline`. |
| `nullSafety` | string | `"off"` | `"strict"`, `"loose"`, `"off"` or `"warn"`: the null-safety checker's mode for this package (below). |
| `outputDir` | string | `"build"` | Where builds go. |
| `dependencies.NAME` | string or table | | One dependency. A version range alone (`ui = "^0.3"`) is a release of the `haxeon` registry, the same as `{ registry = "haxeon", version = "^0.3" }`. A table names its source: `path`, `workspace`, `git` + `rev`, `registry` + `version`, or `haxelib` + `version`. |
| `native` | table | | C and C++ sources: `sources`, `includeDirs`, `std`, `targets`, or `cmake` (`source`, `target`, `inputs`, `library` or `libraries`). |
| `ffi` | table | | `imports`, `interfaces`, `projections`: FFI recipes and interface files ([C_HEADER_FFI.md](C_HEADER_FFI.md)). |
| `app` | table | | Makes the project an app: `name` (the package's by default), `id` (reverse-domain, required), `version` (`1.0.0`), `icon` and `platforms` (at least one of `linux`, `windows`, `macos`, `android`, `web`, `ios`). A project without it is a program ([PROJECT_BUILDS.md](../design/PROJECT_BUILDS.md)). |
| `android` | table | | `applicationId` and `label` of the Android app ([ANDROID.md](ANDROID.md)). |
| `format` | table | tabs, 120 columns | `indent` (`"tabs"` or `"spaces"`), `indentWidth`, `lineWidth` ([CLI.md](CLI.md)). |
| `compatibility` | table | | `haxeon` (a version range), `targets`, `runtimeAbi`, `nativeRequirements`, `features`. |
| `instrument` | table | everything | What `--profile=instrument` probes ([PROFILING.md](PROFILING.md)). |

### Null safety

`nullSafety` turns on the null-safety checker for the package's own code, in one of Haxe's modes: `"strict"` or `"loose"`
(`@:nullSafety(Strict)` and `@:nullSafety(Loose)`), or `"off"`, the default when the key is absent. `"warn"` checks as
`"strict"` does and reports what it finds as warnings, so a project can see what is left to fix while it migrates; any other
value is a manifest error. `haxeon init` writes `nullSafety = "strict"`, so a new project starts null safe.

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
