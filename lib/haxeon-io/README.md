# haxeon-io

Portable building blocks that both builds of the compiler compile: the stock Haxe build (`haxe -hl`, class path `src` plus this
one) and the Haxeon build (this directory is registered with the standard library source roots, so programs Haxeon compiles import
them as standard library too). The packages contain no `haxe.*` types of their own, so they can sit beside the standard library of
either compiler:

- `haxeon.io`: byte sinks, segmented bytes and file trees.
- `toml`: a TOML 1.0 reader (`TomlParser.parse`, giving the values `haxe.Json.parse` gives for JSON, with `TomlDateTime` for dates
  and `TomlError` with the line and column) and writer (`TomlPrinter.print`). Project manifests (`haxeon.toml`) are read with it.
