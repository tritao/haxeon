# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The proof of concept writes HashLink bytecode directly from Haxe. It builds a
recursive `fib` function with symbolic labels and an entry point that calls
`fib(10)`, then passes the result to HashLink's `std@sys_exit` native. Exiting
with status 55 proves that HashLink decoded, linked, branched, and recursively
executed the generated functions.

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
