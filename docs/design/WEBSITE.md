# Website and user documentation

Status: agreed direction (2026-11-22); nothing built yet. The brief for the public site and the user documentation it
publishes: who it is for, what it says, what pages it has, and what has to exist before it launches.

## Position

Haxeon is a language and runtime: one language for apps, tools and games, developed on a live VM, shipped as native
executables or WebAssembly, and calling C and C++ directly. Cross-platform apps are its flagship use case, not its
definition: they get the most space on the site (the demo, the showcase, most guides), and tools, games, scripts and
embedding are shown beside them as what the same language and runtime build. The site presents Haxeon as its own language
and platform, as Kotlin, Swift, Dart and Bun present a language or runtime with several use cases. It is built on Haxe and
compiles a growing subset of it; the site says so on the About page, in the FAQ and on "Coming from Haxe", not in the
headline. Haxeon is independent of the Haxe Foundation: the site uses "Haxe-compatible" and "built on Haxe", never the
Haxe logo or wording that reads as official.

Headline: *A language and runtime for cross-platform apps and tools.* Subheading: *Develop on a live VM that keeps your
program's state as you edit, ship one codebase as native executables or WebAssembly, and call C and C++ directly.* The
headline names what Haxeon is and stays true as it grows; live editing leads the subheading and is the first, largest
proof on the page (the apps demo), because "change it while it runs" alone reads as the hot reload every competitor
claims, and the difference (the whole program, state kept, a failed patch harmless) needs the demo to show.

What sets it apart, each to be shown, not only claimed:

- **Live editing that keeps state:** a property of the runtime, for apps, tools and games alike (logic, data, native
  calls, not only UI); a patch that fails validation leaves the running program untouched.
- **Native interop without a bridge:** bindings generated from C and C++ headers, fixed-layout structs, raw pointers and
  arenas, where Flutter and React Native need platform channels or FFI glue and .NET needs P/Invoke.
- **One codebase, three outputs:** a small JIT VM while developing, executables built ahead of time through C, and
  WebAssembly (`wasm32`, `wasm-gc`) rather than a JavaScript bundle.

What you can build, each linking to a guide, and only what works today:

- **Apps:** desktop, mobile and the web, with the UI package; the largest section, with the demo recording and the
  showcase.
- **Tools and command-line programs:** the `console` template, one executable built ahead of time.
- **Games and 3D:** the GPU, audio and animation packages, glTF.
- **Scripts:** `haxeon script.hx`, no project.
- **Embedding:** the runtime inside a C or C++ host, once its guide exists.

Servers and services are not shown until there is a networking story worth showing.

Batteries included for apps, a compact capability grid in the Apps section, each item linking to its package page or
guide and, where one exists, a real capture:

- **UI that draws itself the same way everywhere** (the `ui` package on the sokol GPU layer): layout (Clay), text shaping
  (HarfBuzz, SkriBidi), bidirectional text (SheenBidi), line breaking (libunibreak, BudouX for CJK), vector drawing
  (NanoVG).
- **Native services from the OS, not reimplemented** (NativeKit, one C API): windows, menus, tray, dialogs,
  notifications, clipboard, WebView, accessibility, input, gamepad and joystick, haptics, sensors, monitors, file watching,
  networking, tasks, GPU surfaces and the mobile hosts.
- **Packages:** `gpu`, `audio`, `animation` (glTF, skeletal), `editor`, `filesystem`, `credentials` (the OS keychain),
  `platform`, `agentkit`.

The grid states maturity as the platform table does: NativeKit is experimental and pre-1.0, with its ABI still evolving,
and the site says so beside it.

Showcase, as proof rather than claims (real, named apps a visitor can inspect beat adjectives):

- **Materia** (github.com/tritao/materia): a reference editor and native UI application.
- **Exosuit** (github.com/tritao/exosuit): an AI agent and code editor built on Haxeon.
- **The UI Showcase**, running in the browser once the web runner lands; Audio Lab for the audio package.
- **Samples to build:** small original games for the games tile (a maze-chase game first, whose enemies' behaviour is tuned
  live while it is played, which doubles as a live-editing clip), later a platformer and a 3D viewer. Original names,
  levels and characters, never recreations of existing games.

Compared with, for apps: Flutter, .NET (MAUI, Avalonia), React Native, Kotlin Multiplatform, Electron and Tauri; as a
language and runtime: Kotlin, Swift, Go, Rust and Dart. The showcase apps
prove range rather than define the audience: an ordinary forms-and-lists app, an editor, a 3D viewer and a small game.

## Platforms, as the site states them

| Platform | Status | Live editing |
| --- | --- | --- |
| Linux (x86-64, arm64) | Supported | Yes |
| macOS (Intel, Apple Silicon) | Supported | Yes |
| Windows (x86-64) | Supported | Yes |
| Android (`arm64-v8a`, `x86_64`) | Supported | Yes |
| Web (WebAssembly) | Experimental | Not yet |
| iOS | In progress | Not yet |

One row per platform, each with a small generic icon (no vendor logos). When a platform's status changes, it changes
here and on the site.

## Page map

- **Home**, in this order (from the homepage research, `docs/reports/2026-11-website-homepage-research.md`):
  1. **Hero:** what Haxeon is (a language and runtime), one sentence, and a short verified program with its output. Primary
     action **Get started**, secondary **See live editing**.
  2. **Apps, the largest section:** a real UI app beside its source (the task list of guide 3). The visitor sees state made
     before an edit (items, a completed one, an unsaved draft), the code change, and the same state after it with the new
     behaviour: retained state visible on both sides, which is the claim no competitor shows. A continuous recording at
     launch, with the reproducible example linked. Then the batteries grid and the showcase (Materia, Exosuit). Actions:
     **Build your first app**, **Get the demo source**.
  3. **The language:** a short tabbed tour, each tab a few lines of code that compile and run, with its output, Haxeon's
     own features first: value types (`struct` with generated equality and hashing), enums and pattern matching, null
     safety, cleanup with `defer`, typed JSON (`JsonWire`, generated, no reflection), zero-cost abstract types. Inference
     shows in every sample rather than as a tab of its own: every competitor has it.
  4. **C and C++ interop:** a real header, the generated binding and the Haxeon call side by side, the result visible.
  5. **One codebase, three outputs:** one sample run on the JIT VM, built as a native executable and as WebAssembly, with
     the real commands and what each produces; the platform table here.
  6. **The whole toolchain, one command:** what ships with Haxeon, each with its command: the language server (`haxeon
     lsp`, used by the VS Code extension), the debugger (Debug Adapter Protocol: breakpoints, stepping, watchpoints,
     logpoints, exception breaks, across a live edit), the formatter and linter (`fmt`, `lint`), the profiler (`run
     --profile`, Perfetto or VS Code), build, check and test, packages (`add`, `publish`, the registry and lockfile), C and
     C++ bindings (`ffi import`), and `doctor`.
  7. **What else you can build:** tiles for tools, games and 3D, scripts and embedding, each with a runnable example and
     its guide.
  8. **Start building:** the shortest install-and-run path on the page (install, create, run), then Get started again.

  No news feed on the home page: verified examples and the platform table show progress better than dated posts.
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
- **Coming from:** Flutter, .NET, Go, each an honest comparison and a translation table; and one page **Coming from Haxe,
  HashLink and Lime** (OpenFL, HaxeFlixel, Heaps, HaxeUI users included). The relation to Haxe is a minor matter on the
  site: one line on About and this page, nothing on the home page. The page answers, with versioned and verified tables
  (`docs/reports/2026-11-website-haxe-ecosystem-research.md`): whether existing `.hx` compiles (the compatibility table,
  `docs/reference/LANGUAGE_SUPPORT.md`, and the first error a reader is likely to hit), what happens to macros, what
  becomes of haxelib, `.hxml`, `-lib` and `-D`, which libraries and frameworks work per output (tested, needs changes,
  unsupported, untested), how JavaScript, hxcpp and HashLink workflows map to Haxeon's (Haxeon's VM is a HashLink fork:
  say what is the same and what differs), and a walkthrough moving a small real project.
- **Reference:** the language, the CLI, the manifest, the packages (`ui`, `platform`, `gpu`, `audio`, `animation`,
  `editor`), the error codes, the standard library API.
- **About:** the project, its maintainers and support channels, and the licenses. The relation to Haxe is told only on the
  Coming from Haxe page; the footer and the rest of the site do not mention it. The name is written Haxeon.

Top navigation: **Language**, **Build** (Apps first, then tools, games and 3D, scripts, embedding; Apps has its own
landing page with the demo, the platform table, the UI package and the first-app guide), **Docs**, **Examples**, **About**,
and a persistent **Get started**. Docs sections: Start here (install, first program, first app), Learn the language (a
tour), Build guides, Runtime and targets (the JIT and live editing, what state survives which edit, executables built
ahead of time, WebAssembly, packaging), C and C++ interop, Reference.

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
- A VS Code extension over the existing language server, with the debugger in it: today debugging goes through the
  vendored HashLink debug adapter, which users set up on their own, so "debug in VS Code" is not one step yet.
- The internal reference pages moved out of the published set (done: `docs/internals/`).

## After launch

- iOS.
- A playground: the compiler in the browser, or a compile server behind it.
- A package registry page.
- The site generator rewritten in Haxeon, once the pages are stable.

## Branding

Haxeon has its own identity: wordmark, icon, palette, favicon, social cards and docs theme, none derived from Haxe's (not
Haxe orange `#EA8220`, not its logo). Haxe is named in plain text only, on About and Coming from Haxe, with Haxeon's
independence from the Haxe Foundation stated there.

## Open

- Domain and hosting.
- A trademark check of the name "Haxeon" before launch: it contains "Haxe", the research found the Foundation's branding
  guidance but no naming policy, and did not establish availability.
