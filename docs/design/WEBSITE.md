# Website and user documentation

Status: agreed direction (2026-11-22); nothing built yet. The brief for the public site and the user documentation it
publishes: who it is for, what it says, what pages it has, and what has to exist before it launches.

## Position

Haxeon is a platform for cross-platform apps: one codebase for desktop, mobile and the web, changed while it runs, with
C and C++ libraries called directly. The site presents Haxeon as its own language and platform. It is built on Haxe and
compiles a growing subset of it; the site says so on the About page, in the FAQ and on "Coming from Haxe", not in the
headline. Haxeon is independent of the Haxe Foundation: the site uses "Haxe-compatible" and "built on Haxe", never the
Haxe logo or wording that reads as official.

Headline: *One codebase for desktop, mobile and the web, that you change while it runs, and that talks to C and C++
natively.*

What sets it apart, each to be shown, not only claimed:

- **Live editing that keeps state** for the whole app (logic, data, native calls, not only UI), and a patch that fails
  validation leaves the running app untouched.
- **Native interop without a bridge:** bindings generated from C and C++ headers, fixed-layout structs, raw pointers and
  arenas, where Flutter and React Native need platform channels or FFI glue and .NET needs P/Invoke.
- **Lean outputs:** a small VM, executables built ahead of time through C, and WebAssembly (`wasm32`, `wasm-gc`) rather
  than a JavaScript bundle.

Compared with: Flutter, .NET (MAUI, Avalonia), React Native, Kotlin Multiplatform, Electron and Tauri. The showcase apps
prove range rather than define the audience: an ordinary forms-and-lists app, an editor, a 3D viewer and a small game.

## Platforms, as the site states them

| Platform | Site wording |
| --- | --- |
| Linux, macOS (x86-64, Apple Silicon), Windows | Supported |
| Android (`arm64-v8a`, `x86_64`) | Supported, with live editing |
| Web (WebAssembly) | Experimental |
| iOS | Planned |

The table follows README.md; when a platform's status changes there, it changes here and on the site.

## Page map

- **Home:** the headline, a 30-second recording of an app edited while it runs, the three differences, the platform
  table, and the UI Showcase running in the browser.
- **Get started** (`docs/guides/00-get-started.md`): install a C and C++ toolchain and CMake (the one command for each
  system, as `haxeon doctor` prints it), then Haxeon from a release archive (`docs/reference/RELEASES.md`; no
  checkout), then "Your first app".
- **Guides** (tutorials and how-tos), in the order they are written:
  1. Your first app: one project built for desktop, Android and the web.
  2. Live editing: what a patch can change, what needs a reload, and how state carries across.
  3. UI basics: layout, text, lists, forms, navigation, theming.
  4. Calling a C or C++ library.
  5. Shipping: desktop executables, Android packages, the web bundle.
  6. Use cases: an editor, a 3D app (GPU, camera, glTF), a game loop with live-tweaked logic.
- **Coming from:** Flutter, .NET, Haxe. Each is an honest comparison and a translation table. "Coming from Haxe" holds
  the compatibility table (`docs/reference/LANGUAGE_SUPPORT.md`).
- **Reference:** the language, the CLI, the manifest, the packages (`ui`, `platform`, `gpu`, `audio`, `animation`,
  `editor`), the error codes, the standard library API.
- **About:** the project, its relation to Haxe and HashLink, the licenses.

## Documentation rules

- **One source.** The site is built from Markdown in this repository, on every release, with the release's version
  shown and `main` selectable. Nothing is written twice.
- **Pages by kind:** tutorials and how-tos (new, under `docs/guides/`), reference (`docs/reference/`), explanation. A
  user page never links into `docs/design/` or `docs/reports/`.
- **User and internal reference apart.** Pages about the compiler's and the runtime's internals live in `docs/internals/`
  (`HLB_DEBUG_SECTIONS`, `HLD3_DEBUG_PROTOCOL`, `METADATA_OWNERSHIP`, `SEMANTIC_TYPE_CONTRACT`, `IR_ALLOCATION_REPORT`,
  `JIT_NATIVE_PROPERTIES`, `HASHLINK_MODULE_RECLAMATION`, `GENERIC_SPECIALIZATION`, `BENCHMARKS`), which the site does
  not publish. Making a release is in `docs/DEVELOPMENT.md`; `docs/reference/RELEASES.md` is what a release holds and
  how to install it. The `docs-guides` suite checks that no guide or reference page links outside guides and reference.
- **Generated where code is the source:** the CLI reference from `CliHelp`, one page per error code (`E1xxx`) with an
  example, the package and standard library API from doc comments, the compatibility table from the differential tests.
- **Every code block is compiled in CI**, and run where the page shows its output. A guide's code is an example project under
  `docs/guides/examples/`, and its code blocks are excerpts of it (`docs/guides/README.md`).

## Native code

An app that uses a package wrapping C or C++ (the UI package does) builds that code with the user's own C and C++
toolchain and CMake, once per machine and set of options, in a cache every project shares. `haxeon doctor` checks the
toolchain and names the command that installs it. Packages ship sources, not prebuilt libraries: prebuilt libraries would
cover only the packages whose authors build every target, and not an executable built ahead of time through C. Bundling a
compiler is the next step if the install proves the obstacle (TODO.md).

## Site

The documentation pages are static HTML from an existing docs generator (Astro Starlight unless a reason against it
turns up), so they load fast, are indexed, and work without WebAssembly. The site source lives in this repository under
`site/` and reads `docs/`, so a change and its documentation land in one commit. Haxeon-built WebAssembly runs where it
shows something: the UI Showcase on the home page and, later, a playground.

## Before launch

- The "Get started" path works from a release archive on Linux, macOS and Windows.
- The first-party packages (`ui`, `platform`, `gpu`, `audio`, `animation`, `editor`) are releases of the `haxeon`
  registry that a release archive ships, so a new project depends on them as `ui = "^0.3"`.
- `haxeon create my_app` makes a windowed app with its runner projects ([PROJECT_BUILDS.md](PROJECT_BUILDS.md)), which
  `haxeon run` opens and `haxeon run --watch --live` edits.
- Guides 1 to 5 written and their code compiled in CI.
- The home page recording, and the UI Showcase on the web.
- A VS Code extension over the existing language server.
- The internal reference pages moved out of the published set (done: `docs/internals/`).

## After launch

- iOS.
- A playground: the compiler in the browser, or a compile server behind it.
- A package registry page.
- The site generator rewritten in Haxeon, once the pages are stable.

## Open

- Domain and hosting.
