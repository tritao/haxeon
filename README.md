# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The proof of concept writes HashLink bytecode directly from Haxe. It builds an
`add` function and an entry point that calls `add(20, 22)`, then passes the
result to HashLink's `std@sys_exit` native. Exiting with status 42 proves that
HashLink decoded, linked, and executed both generated functions.

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
