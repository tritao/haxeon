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

Do not put compiler implementation sources from HaxeFoundation/haxe here. The
compiler and the standard library have different licenses.
