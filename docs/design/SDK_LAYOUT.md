# One SDK layout for releases and checkouts

Status: agreed (2026-11-23). Steps 1 (out/sdk staged, one SDK lookup, releases ship `sdk/`) and 2 (runners use
`find_package(Haxeon)` and a data-only fragment) are built; 3 to 6 are open. Reviewed independently before adoption; the
five changes from that review are folded in below.

## Problem

A release and a checkout lay Haxeon out differently, and code branches on which one it is:

- A release has `bin/`, `stdlib/`, `templates/` and `haxeon-release.txt` (`src/tools/dev/ReleasePackage.hx`); a checkout has
  `out/cmake/release/hashlink-runtime/`, `out/cmake/release/hlc-sdk/` and `scripts/haxeon`.
- The launcher (`native/haxeon_main.c`) has compiled-in checkout paths and a release mode; `HaxeonRelease.isRelease` and
  `HashLinkPath` branch on the layout; the hlc SDK is found by three separate lookups (`src/tools/AppRunner.hx`,
  `src/tools/dev/AotBuild.hx`, `src/compiler/backend/c/HlcBuild.hx`).
- The release layout is defined twice: in `ReleasePackage` and in the `haxeon-hlc-sdk` CMake target.
- A release is assembled apart from what developers run, so a feature can work in a checkout and break in a release. Today
  `haxeon create` apps build only in a checkout, and the app template writes the absolute path of the checkout's
  `packages/ui` into the user's manifest.

Every new piece an app needs (the runner's SDK, packages, templates, the Android host, a web loader) would add another
release-or-checkout branch.

## Decision

**One SDK layout.** A checkout's native build installs into `out/sdk` with the layout a release ships, and a release is an
archive of it. Haxeon's home is always an SDK root, found from the executable (`bin/..`), as Go and Zig find theirs.

```
<sdk>/
  haxeon-sdk.toml          the manifest: version, target, and where the roots below are
  bin/                     haxeon, hl, haxeon-aot
  lib/<target>/            libhl (JIT), libhl-aot, libhaxeon-app, libffi; compiler and CLI bytecode
  include/                 the runtime headers
  cmake/                   HaxeonConfig.cmake and HaxeonConfigVersion.cmake: find_package(Haxeon)
  src/                     haxeon_app.c, hlc_main.c, hlc_stack.c
  stdlib/  templates/  registry/
  platforms/<target>/      the Android host, the web loader, as their runners land
```

Libraries are per target from the start (`lib/linux-x86_64-gnu/`, later `lib/android-arm64/`, ...): a release is per host,
but an app targets other platforms too. `HaxeonConfig.cmake` selects by `CMAKE_SYSTEM_NAME` and processor.

**SDK root and source root are different things.** Much of what code reads from home today exists only in a checkout:
`.tools/`, `src/`, `tests/`, `bootstrap/compiler.hl`, `vendor/hashlink`, `android/`. The manifest has an optional
`source = "<checkout>"`; `haxeon dev`, the pinned-Haxe rebuild of the compiler and the stale-compiler check ask whether there
is a source root, one capability check instead of layout branches.

**Built files are installed; source trees are named, not copied.** Copies of `stdlib/`, `templates/` and packages in
`out/sdk` would go stale after an edit, send go-to-definition to the copies and make `run --watch --live` watch the wrong
files. The manifest names those roots: relative to the SDK in a release, the checkout's own directories in a checkout. The
code path is the same; only the manifest differs.

**Runners consume the SDK as a CMake package.** A runner's `CMakeLists.txt` includes the generated fragment, then
`find_package(Haxeon <version> REQUIRED)` and `haxeon_add_app(...)`. The fragment is data only: the app's fields, its
module, the native packages' directories and targets, and a `Haxeon_DIR` hint; adding the packages to the graph is an SDK
function. The package's version file replaces the unchecked `HAXEON_RUNNER_VERSION`, and `AppRunner` reconfigures when the
SDK it configured with changes.

## Packages and the registry

- First-party packages stay in this repository, versioned in lockstep with Haxeon (`PackageCompatibility.CURRENT_HAXEON`),
  so a typer or standard-library change and the packages it affects land together. The registry boundary keeps a later
  split possible.
- The `haxeon` registry is part of the SDK: in a release, an unpacked index and its packages (`registry/index.json`,
  `registry/<name>/<version>/`); in a checkout, a generated index whose entries resolve to `packages/<name>` live, so edits to
  packages show on the next build and live patching keeps working. The resolver consults the SDK's registry first, a network
  index later, under the same name.
- **Lockfile:** a release SDK writes and verifies checksums. A checkout SDK accepts any `haxeon`-registry lock entry whose
  version is in range, verifies nothing and never rewrites it, so a project's lockfile is the same whichever is used. After
  an upgrade whose locked version is absent, resolution picks again within the range, unless `--locked`.
- **Overrides:** a Cargo-style `[patch.haxeon]` (in the project or the user's settings) points a package at a local
  directory without editing dependency lines. A clone's `out/sdk/bin` on `PATH` is the toolchain, as `rustup toolchain
  link` makes one.
- **Publishing** gives packages versions, names them as projects write them (`ui`, `platform`, ...), rewrites path
  dependencies between them to version ranges, includes only what builds (submodules materialized, vendored code trimmed),
  and adds a `nativekit` package wrapping NativeKit, which the others depend on in place of their `../../vendor/nativekit`
  fallbacks. The NativeKit settings `AppRunner` writes today (`NK_BUILD_*`) move into that package.
- Projects state `compatibility.haxeon`; `haxeon create` writes it with `ui = "^0.3"` and no path.

## Risks

- **A prebuilt `libhaxeon-app` against the user's toolchain:** MSVC runtime flavor, the glibc baseline of the build
  machine, LTO objects. Build it on an old baseline without LTO, and keep the option of compiling the VM from the SDK's
  sources in the app's graph.
- **Publishing in place:** `out/sdk/bin` becomes what running sessions execute, so it keeps the staging-then-rename publish
  (`cmake/haxeon-publish.cmake`).
- **Checkout-only tools:** Ninja and ccache are looked up under the checkout's `.tools` (`NativeCMakeProvider.ninjaExecutable`);
  a release finds them on `PATH` or ships them.
- **Programs with native packages** compile against `vendor/hashlink` headers; they move to the SDK's `include/`.

## Alternatives not taken

- **The SDK is a git checkout (Flutter):** a clone needs the pinned Haxe bootstrap and a native build, and users would not
  run the tested artifact. Kept from it: the tool rebuilds itself when invoked (`scripts/haxeon`).
- **A toolchain manager (rustup):** premature; `compatibility.haxeon` and a linked toolchain on `PATH` are enough until
  several installed versions matter.
- **Packages in their own repositories:** loses atomic compiler and package changes, for no present gain.

## Migration

About ten files hard-code `out/cmake/release`; nearly everything else goes through `cmake/hashlink-output-paths.txt` and
`scripts/hashlink-path.sh`, so the published directory can move by editing one table.

1. **Stage `out/sdk`, moving no paths.** Install rules and a target that stage `lib`, `include`, `cmake/HaxeonConfig.cmake`,
   `src` and the manifest, superseding `hlc-sdk`; one `HaxeonSdk.root(home)` replaces the three hlc SDK lookups; the
   release copies the staged SDK; `scripts/smoke-test-release.sh` creates, builds and runs the app template from the archive.
2. **Runner:** `find_package(Haxeon)`, the data-only fragment, the version check, reconfigure on an SDK change.
3. **Launcher and home:** the launcher finds its SDK from its own path and reads the manifest with its `source` field; the
   path table moves to `out/sdk/bin`, `hashlink-runtime` and `HaxeonRelease.isRelease` go. Announced to the other sessions:
   each worktree rebuilds once.
4. **Packages:** versions, the `nativekit` package, publishing with rewritten dependencies, the SDK registry (generated in
   a checkout, unpacked in a release), the lockfile rule and `[patch.haxeon]`; the template uses `ui = "^0.3"`.
5. **Release:** `haxeon dev package` becomes the install, the named roots materialized, and an archive; CI runs the template
   tests against the archive.
6. **Other targets:** `platforms/android` (the host AAR, per-ABI libraries) and `platforms/web` as their runners land; a
   network registry after that.

Release builds through the runner (`PROJECT_BUILDS.md`, step 2) follow step 2 here, on the SDK's `Haxeon::aot` target.
