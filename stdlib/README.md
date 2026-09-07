# Realtime Haxe standard library

This directory contains the source-level standard library compiled by
realtime-haxe. Sources under `haxe/` are selectively adapted from the Haxe
4.3.7 standard library rather than copied wholesale: the compiler currently
uses a deliberately smaller language and runtime ABI than the official Haxe
HashLink target.

The pinned upstream version and every imported file are recorded in
`UPSTREAM.md`. Imported sources retain their upstream copyright and MIT
license notices. Keep local compatibility edits small and document them next
to the source entry.

Declarations under `hl/` are target ABI façades owned by this project. They
carry explicit representation metadata and are not copies of upstream stdlib
implementations.

Register this directory with `Compiler.addSourceRoot("stdlib")`. Modules are
then discovered from their imports and type references, loaded only when they
enter the reachable dependency graph, and retained in the compiler's module
cache. Explicitly supplied modules take precedence over files in source roots.

Do not put compiler implementation sources from HaxeFoundation/haxe here. The
compiler and the standard library have different licenses.
