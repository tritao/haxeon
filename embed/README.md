# Embedded compiler and runtime

Depend on the `haxeon-compiler` package at this directory to compile and run
Haxeon source inside a host application:

```json
"dependencies": {
  "haxeon-compiler": { "path": "../haxeon/embed" }
}
```

The package exposes the existing `compiler` and `runtime` APIs from `src`.
It has no entry point and leaves their package names unchanged. The host CLI
supplies the matching standard library and native runtime; this is currently a
HashLink host package.

Create a compiler with `new Compiler(null, CompilerIntrinsics.configuration())`.
Register any host interfaces with `addFfiInterface` before the first compile,
then update source modules and compile an entry module. Add source roots for
libraries used by generated programs; the compiler does not automatically
inherit the host application's sources.

Load `HlWriter.encode(build.module)` with `build.runtimeIdentity` through
`Runtime.load`, invoke the stable IDs in `build.functionIds`, and dispose the
loaded module when finished. Module-level functions use unqualified export
names; class methods use their qualified names. Live updates require publication
tracking and acknowledgement/rejection of the compiler's proposed revisions.

`tests/integration/test-compiler-embedding.sh` builds a package consumer that
compiles a guest program and executes its exported function. It also accepts
`--self-hosted` to check the refreshed bootstrap compiler.
