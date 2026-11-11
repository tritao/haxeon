# haxeon-io

Portable I/O building blocks that both builds of the compiler compile: the stock Haxe build (`haxe -hl`, class path `src` plus this
one) and the Haxeon build (this directory is registered with the standard library source roots). The package contains no `haxe.*`
types of its own, only `haxeon.io.*`, so it can sit beside the standard library of either compiler.
