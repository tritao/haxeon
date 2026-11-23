# Guides

Step-by-step guides to building apps with Haxeon. Read them in order: each one builds on what the one before it showed.

0. [Get started](00-get-started.md): install a C and C++ toolchain, CMake and Haxeon, and check them with `haxeon doctor`.
1. [Your first app](01-first-app.md): create an app, run it, change it and build it for shipping.
2. [Live editing](02-live-editing.md): change an app while it runs, and what an edit can change without a restart.
3. UI basics: layout, text, lists, forms, navigation, theming. (Not written yet.)
4. Calling a C or C++ library. (Not written yet.)
5. Shipping: desktop executables, Android packages, the web bundle. (Not written yet.)

The commands and options are in the [CLI reference](../reference/CLI.md), and the project file in the
[manifest reference](../reference/MANIFEST.md).

## Writing a guide

Every piece of code a guide shows is part of a project that is built in CI, so a guide cannot show code that does not
compile.

- A guide is `NN-slug.md` in this directory, numbered in reading order. Its code lives in `examples/NN-slug/`: one or
  more ordinary Haxeon projects (each a directory with a `haxeon.toml`), plus any other files the guide needs, such as the
  versions of a file the reader changes step by step.
- Every ` ```haxe ` and ` ```toml ` block on the page must appear in a file under `examples/NN-slug/`, line for line. The
  check ignores the block's common indentation, so a method can be shown without the indentation of its class, and
  trailing spaces. A line that holds only `// ...` (in Haxe) or `# ...` (in TOML) stands for lines left out: the parts
  around it must appear in the same file, in that order.
- A ` ```text title="Output" ` block is what a program prints: it must appear in that project's `expected-output.txt`,
  and the check runs the program and compares what it prints with that file.
- Commands go in ` ```sh ` blocks (` ```powershell ` for Windows only) and other output in ` ```text ` blocks; neither
  is checked against the examples, so keep them to what the reader types and sees.
- A guide links only to other guides, to reference pages (`../reference/`) and to full URLs. It never links into
  `docs/design/`, `docs/reports/`, `docs/internals/` or `docs/adr/`: those are not published. Reference pages follow the
  same rule, and the check below checks theirs too.
- An app is kept without its runner directories (`linux/` and the others): the check adds them with `haxeon create .`, so
  an example always has the runner the current template writes.

`tests/integration/test-docs-guides.hx` checks all of this, then copies each example project out of the tree and builds
it with the checkout's `haxeon`. It runs a program and compares its output when the project has an
`expected-output.txt`, and opens an app for a few frames (under `xvfb-run` on Linux when it is installed). A guide that
needs more, such as the live edits of [Live editing](02-live-editing.md), gets its own function there. Run it from the
repository root:

```sh
scripts/haxeon tests/integration/test-docs-guides.hx               # check the pages, then build and run every example
scripts/haxeon tests/integration/test-docs-guides.hx --no-build    # check the pages only
```
