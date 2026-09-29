# Assemblies as data: H0 feasibility probes

## Abstract operators

`operators/src/Main.hx` exercises `@:op(A + B)`, `@:op(A * B)` and
`@:op(A < B)` on an `abstract Millimetres(Float)`.

Run `scripts/haxeon run --project tests/feasibility/operators/haxeon.json`.
At `bd014aec`, compilation stopped at `a + b` with E1010, "Arithmetic requires
matching numeric operands". H4 added dispatch through the abstract's declared
`@:op` methods. The probe now compiles and runs; the runtime suite also covers
Int and Float abstracts, unary negation, comparisons, and invalid declarations.

## FFI struct output array

Import `ffi-struct-array.h` with:

```sh
scripts/haxeon-ffi-import \
  --target=x86_64-linux-gnu \
  --library=probe --interface=Probe \
  --output=/tmp/hxi-struct-array-probe.hxi \
  "$PWD/tests/feasibility/ffi-struct-array.h"
```

At `bd014aec`, the importer succeeds and emits
`points: nullable<ptr<hxi_probe_point>> @out_array("count")`. This confirms
the C header can be represented in HXI. It does not establish whether a
convenient generated Haxe API or a runtime call works; C import's
`--haxe-output-dir` option is restricted to C++.
