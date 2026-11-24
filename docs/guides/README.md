# Guides

Step-by-step guides to building apps with Haxeon. Read them in order: each one builds on what the one before it showed.

0. [Get started](00-get-started.md): install a C and C++ toolchain, CMake and Haxeon, and check them with `haxeon doctor`.
1. [Your first app](01-first-app.md): create an app, run it, change it and build it for shipping.
2. [Live editing](02-live-editing.md): change an app while it runs, and what an edit can change without a restart.
3. [UI basics](03-ui-basics.md): layout, text, lists, forms, navigation and theming, in a small task list app.
4. [Calling a C or C++ library](04-calling-c-and-cpp.md): import a header, build the library with CMake, and call it.
5. [Shipping](05-shipping.md): a desktop executable built ahead of time, Android packages and the web, as far as each goes.

The commands and options are in the [CLI reference](../reference/CLI.md), and the project file in the
[manifest reference](../reference/MANIFEST.md).

To study the syntax, read [Learn the language](../learn/README.md). To bring experience or code from another platform,
start with [Coming from another platform](../coming-from/README.md).

## Writing pages with examples

CI builds the example projects for the guides, the language tour and the migration pages.

- Name a guide `NN-slug.md` in reading order. Name a language or migration page `slug.md`. Put a page's code in
  `examples/<page>/` beside it, using the filename without `.md` as `<page>`. The directory holds one or more Haxeon
  projects, each with a `haxeon.toml`, and any other files needed to follow the page, such as step-by-step edits.
- Every ` ```haxe ` and ` ```toml ` block on the page must appear in a file under `examples/<page>/`, line for line. The
  check ignores the block's common indentation, so a method can be shown without the indentation of its class, and
  trailing spaces. A line that holds only `// ...` (in Haxe) or `# ...` (in TOML) stands for lines left out: the parts
  around it must appear in the same file, in that order.
- A ` ```text title="Output" ` block is what a program prints: it must appear in that project's `expected-output.txt`,
  and the check runs the program and compares what it prints with that file.
- Commands go in ` ```sh ` blocks (` ```powershell ` for Windows only) and other output in ` ```text ` blocks; neither
  is checked against the examples, so keep them to what the reader types and sees.
- For code in another language, label the block with that language, such as `dart`, `csharp` or `go`.
- Published pages link to guides, language pages, migration pages, reference pages and their examples, or to full URLs.
  Keep links to design notes, reports, internals and decision records in repository documentation.
- An app is kept without its runner directories (`linux/` and the others): the check adds them with `haxeon create .`, so
  an example always has the runner the current template writes.

`tests/integration/test-docs-guides.hx` checks snippets and published links, then copies each example project out of the tree
and builds it with the checkout's `haxeon`. It runs a program and compares its output when the project has an
`expected-output.txt`, and opens an app for a few frames (under `xvfb-run` on Linux when it is installed). A guide that
needs more, such as the live edits of [Live editing](02-live-editing.md), gets its own function there. Run it from the
repository root:

```sh
scripts/haxeon tests/integration/test-docs-guides.hx               # check the pages, then build and run every example
scripts/haxeon tests/integration/test-docs-guides.hx --no-build    # check the pages only
```
