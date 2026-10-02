# Development

## 🚀 Run the proof of concept

Initialize the pinned tools, verify formatting, bootstrap the compiler, and run
the integration suites:

```sh
./scripts/bootstrap-tools.sh
./scripts/format.sh --check
./scripts/bootstrap-status.sh
./scripts/bootstrap-compiler.sh
./scripts/bootstrap-compiler.sh --self
./scripts/test.sh
./tests/integration/test-hot-reload.sh
```

The full test script runs program fixtures with 16 workers by default. Set
`TEST_JOBS=1` for the sequential baseline, or invoke the driver directly to
select a suite or test:

```sh
TEST_JOBS=1 ./scripts/test.sh
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite programs --jobs 16
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite compiler --test ParserRecovery
```

The cross-platform Haxe build entry point provides the native build, bootstrap,
and core test workflow without Bash. This is the path used by Windows CI:

```sh
.tools/haxe/haxe -cp src --run build.HaxeonBuild native
.tools/haxe/haxe -cp src --run build.HaxeonBuild bootstrap-self
.tools/haxe/haxe -cp src --run build.HaxeonBuild test 16
```

`bootstrap/compiler.hl` is checked in. For ordinary compiler development,
`bootstrap-compiler.sh --self` rebuilds it with the checked-in compiler and
pinned HashLink without invoking the reference Haxe compiler.

The full bootstrap uses pinned reference Haxe to build the compiler, then asks
that compiler to build itself and requires byte-for-byte equality. Both modes
derive the same sorted source manifest from `src/` and build the native runtime
bridge before compilation.

The writer currently targets HashLink bytecode format version 6, matching the
decoder in `src/code.c`.

## API documentation

Haxeon recognizes Haxe documentation comments beginning with `/**`. Their
Markdown and `@param`, `@return`/`@returns`, `@deprecated`, `@see`, `@throws`,
`@exception`, and `@since` tags are shared by editor hover, completion, and
signature help.

The compiler can also emit deterministic Haxe type-description XML for tools
such as [dox](https://github.com/HaxeFoundation/dox):

```sh
compiler.hl --xml=docs/api.xml --output=out/app.hl \
  --entry=my.app.Main --root=src src/my/app/Main.hx
haxelib run dox -i docs -o docs/html
```

Both `--xml=docs/api.xml` and the standard two-argument form
`--xml docs/api.xml` are accepted. Documentation generation does not change
runtime fingerprints or hot-reload compatibility.

## Native build

Haxeon uses CMake for its cross-platform native build and Ninja as the default
backend. HashLink is built from the pinned `vendor/hashlink` submodule; the
resulting VM and library are placed in `.tools/hashlink`, while Haxeon's runtime
HDLL is placed in `out`.

The Release preset owns those shared tool paths. The Debug preset writes its VM
and runtime HDLL under `out/cmake/dev` so a development build cannot replace
the optimized VM used by profiler captures and normal project commands.

```sh
cmake --preset release
cmake --build --preset release
```

The same build can be driven by the cross-platform Haxe entry point:

```sh
.tools/haxe/haxe -cp src --run build.HaxeonBuild doctor
.tools/haxe/haxe -cp src --run build.HaxeonBuild native release
```

On a fresh Windows checkout, run `scripts/setup.ps1` from a Visual Studio
developer shell. It installs the pinned tools and selects the `windows-msvc`
preset. The CI job also builds and tests `windows-msvc-debug`, which uses the
matching MSVC Debug CRT. Later native-only builds can use
`scripts/build-native.ps1`. Unix environments may use
`scripts/bootstrap-tools.sh` followed by
`scripts/build-native.sh`; macOS CI covers both Intel and Apple Silicon, with
the latter using HashLink's AArch64 JIT. The `macos-arm64` preset can also be
used for an explicit arm64 build on Darwin. Set `HAXEON_CMAKE_PRESET` to
override the wrapper's default preset.

Linux AArch64 hosts need `qemu-user` and `libc6-amd64-cross`: the pinned Haxe
release is currently Linux x86-64, so the shared bootstrap keeps the normal
`.tools/haxe/haxe` path and runs that compiler through an explicit QEMU
wrapper. The native HashLink and runtime still build and execute for AArch64.

Pinned tool versions, archive checksums, extraction, and submodule setup are
defined once in `cmake/Bootstrap.cmake`. The platform setup scripts are thin
launchers for that shared bootstrap rather than separate installers.

Haxe sources use the repository-pinned Haxe Formatter:

```sh
./scripts/format.sh
./scripts/format.sh --check
```

`bootstrap-status.sh` runs the real lexer, parser, and typer over the compiler
source tree and reports bootstrap progress. Pass `--json` for a machine-readable
dashboard.

