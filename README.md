# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The proof of concept compiles a small Haxe-compatible source file through a
lexer, parser, AST, typed IR, and HashLink backend. The generated entry point
passes the source `main()` result to HashLink's `std@sys_exit` native, making
the result observable to the integration test.

The example is expressed as typed, register-independent IR. `HlLower` assigns
function/type/register indices, interns constants and native names, and lowers
the IR to the serialized HashLink model.

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
