# Tools

## lsp

`haxeon lsp` is the Language Server Protocol server, over standard input and output; the VS Code extension starts it
(`haxeon.server.path` and `haxeon.server.args`).

## ffi

### import

`haxeon ffi import ...` imports C and C++ headers as HXI ([C_HEADER_FFI.md](../C_HEADER_FFI.md)); a project's `ffi`
recipes run it during the build.

`haxeon ffi import` resolves relative paths against the directory it is run from, like every other command.

### audit

`haxeon ffi audit ...` imports one public header for several targets and compares their C ABIs.

## heap

## identity-path

## dev

`haxeon dev` runs the commands for working on Haxeon itself. It runs only from a Haxeon checkout and says so elsewhere.

## version

`haxeon --version` (or `haxeon version`) prints the CLI’s version, the checkout commit its compiler is built from and
the HashLink version, as `haxeon 0.3.0 (compiler 7970f0eaaa86, HashLink 2.0.0)`.

## help

See [Help](../CLI.md#help) for the ways to request command help.
