# Packages

## add

Dependencies can be added and installed reproducibly. `haxeon add NAME` adds the latest release of `NAME` that is not
yanked from the `haxeon` registry, written as its version range alone (`ui = "^0.3.1"`); `--version RANGE` picks the
range and `--registry NAME` another registry, written as `{ registry = NAME, version = RANGE }`:

```sh
haxeon add ui
haxeon add ui --version "^0.3"
haxeon add widgets --registry local
haxeon add --git https://github.com/example/foo.git --rev main foo
```

## install

`install` records the requested source and resolved Git commit in
`haxeon.lock`; `install --locked` rejects manifest changes and checks out the
exact recorded revision.

Registry sources use the same lockfile path. A registry index records immutable
release checksums, SemVer versions, yanked status, compatibility metadata, and
native provider metadata.

`install --locked` is strict: a locked registry version that is gone is an error, where a build or `install` picks again within the range.

```sh
haxeon install
haxeon install --locked
```

### Local path dependencies

Host builds resolve local path dependencies declared by package name. A
dependency can provide Haxe sources and optional C sources; C sources are
compiled into the HashLink native library requested by the build:

```toml
version = 1
entry = "Main"
sourceRoots = ["src"]
target = "host"
outputDir = "build"

[package]
name = "my-app"

[dependencies]
foo = { path = "../foo" }
```

The `foo` package can list native inputs in its own manifest:

```toml
version = 1
sourceRoots = ["src"]

[package]
name = "foo"

[native]
sources = ["native/foo.c"]
includeDirs = ["native/include"]
std = "c++20"
```

The optional native `std` value controls compilation of package-owned C and
C++ sources. It is separate from the `std` value in an FFI recipe, which
controls Clang's header import and generated thunk compilation. CMake-backed
packages continue to declare their language standard in `CMakeLists.txt`.

Native packages may instead delegate an existing CMake project as one coarse
provider:

```toml
[native]
cmake = { source = "native", target = "foo" }
```

Native providers advertise their supported targets with `native.targets`; the
default source and CMake providers support `host` and `android`. If a package
has no provider for a requested target, planning stops with the package and
missing-provider chain—for example, `foo cannot be built for wasm32`—before
compilation or linking begins.

Packages can also gate resolution with compatibility metadata:

```toml
[compatibility]
haxeon = ">=0.3"
targets = ["host", "android"]
runtimeAbi = "2"
```

These requirements are checked while resolving the package graph, before any
compiler or native action is planned.

### Haxelib

Haxelib is an adapter, not Haxeon's package model. A pure-Haxe Haxelib release
can be placed in the dedicated `~/.haxeon/cache/sources/haxelib/<name>/<version>`
cache (or supplied as an archive under its downloads cache); its `haxelib.json`
is translated to a normal Haxeon manifest. Haxeon does not read global
`haxelib dev` state or execute `extraParams`, macros, or HXML compiler settings;
unsupported settings fail with an explicit import diagnostic.

## update

```sh
haxeon update
```

## tree

```sh
haxeon tree
```

## why

```sh
haxeon why foo
```

## publish

For local development, `publish` writes an immutable
release and index below `~/.haxeon/cache/sources/registry`; projects then use
`core = { registry = "local", version = "^1.0" }` and resolve through the normal
package graph. A dependency on the `haxeon` registry is written as its range alone,
`core = "^1.0"`; that registry is the SDK's first, then the cache's. See the [manifest reference](../MANIFEST.md#the-haxeon-registry).
`publish` turns path dependencies on packages of the registry into version ranges and refuses others, and copies the
files Git tracks (submodules included) or, outside a repository, every file, less the manifest's
`publish.exclude`.

```sh
haxeon publish --registry local --version 1.0.0
```

## package

### check

```sh
haxeon package check
```
