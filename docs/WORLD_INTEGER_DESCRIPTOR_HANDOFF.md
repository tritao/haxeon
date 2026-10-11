# Native integer defaults and descriptor range hashing

This checkpoint repairs two descriptor failures found by World SC1's bounded native integer profile. It is based on compiler checkpoint `6487a70c` in this isolated review checkout; it does not change World or runtime dependency pins.

## Supported source shape

```haxe
@:annotation struct Range {
	public var min:Float;
	public var max:Float;
}

struct RuntimeIntegerDefaults {
	public var signed:Int32 = 123456789;
	@:Range(0.0, 4294967295.0) public var unsigned:UInt32 = 0;
	public var highBits:UInt32 = -1;
}
```

`Int32` defaults use the signed 32-bit `Int` value directly. `UInt32` uses the same `Int` carrier bit pattern: `-1` is the exact `0xFFFFFFFF` value, and values with the high bit set remain negative carriers. An integer token `4294967295` is outside Haxeon's signed 32-bit literal range and still reports E0002; write the intended signed carrier (`-1` for all bits set) rather than converting it through Float.

World can validate the JSON sidecar with `MessagePackSchema.fromJson`, then query defaults with `fieldDefaultValue(hash, type, path)`. The range metadata remains typed `Float`; `4294967295.0` is exactly representable as a binary64 value.

## Root causes and repairs

- Descriptor default extraction treated `Int32` and `UInt32` native scalar aliases as unsupported because they have no narrow 8/16-bit range. The compiler and both descriptor validators now accept their exact 32-bit `Int` carrier values. Narrow scalar bounds remain enforced.
- JSON serialization rendered an integral `Float` range endpoint above signed `Int` max as an integer token. Haxeon's JSON parser wrapped that token to a signed `Int`, so runtime descriptor hash validation recomputed different annotation facts. The descriptor writer now preserves a Float parse token for such values (for example, `4294967295.0`) before hash validation. It does not convert a UInt32 carrier to Float.

World's original pinned compiler reported E1024 for `Int32 = 123456789` and `UInt32 = 0`. A `UInt32` range annotation ending at `4294967295.0` compiled but failed `MessagePackSchema.fromJson` with a descriptor content hash mismatch. Both cases now pass in the isolated consumer fixture. Defaults `123456789`, `0`, and `-1` survive typeInfo and schema lookup with exact `Int` values; the sidecar's Float range endpoint is validated by the runtime schema reader.

## Verification on this checkpoint

- `bash tests/integration/test-type-descriptor-artifact.sh` — pass, including the large UInt32 bound, nested defaults, and exact high-bit carrier values.
- `SKIP_FORMAT_CHECK=1 TEST_JOBS=4 scripts/test.sh` — 533 driver cases passed, all integration stages passed, and 362 Wasm parity fixtures agreed (16 skips). The global formatting stage was skipped because two unrelated files already fail it; changed Haxe files passed targeted formatter checks.
- `scripts/bootstrap-compiler.sh` — pass; stages converged after 2 self-host stages.
- `scripts/bootstrap-compiler.sh --self` — pass; checked-in compiler rebuilt itself identically.
- `scripts/check-self-hosting.sh` — pass; the compiler built itself to a fixed point.

Wasm32 freshness was skipped because no clang with a wasm32 target is installed, and Wasmtime execution checks were skipped because Wasmtime is unavailable. Those skips do not affect the recorded parity fixture result.
