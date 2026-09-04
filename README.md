# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The first proof of concept writes HashLink bytecode directly from Haxe. It
builds a two-instruction entry point that loads `42` and calls HashLink's
`std@sys_exit` native. Exiting with status 42 proves that HashLink decoded,
linked, and executed the generated function.

## Run the proof of concept

```sh
./scripts/bootstrap-tools.sh
./scripts/test-poc.sh
```

Bootstrap/reference Haxe and HashLink binaries are downloaded or built below
`.tools/`; they are not system-installed or committed. Normal development will
eventually use the checked-in bootstrap compiler instead of official Haxe.

The writer currently targets bytecode format version 6, matching the current
HashLink decoder in `src/code.c`.
