# Haxeon gpu package

This package owns NativeKit's Haxeon GPU API bindings and managed wrappers. NativeKit owns the public C headers, native implementation, and native tests.

The first extraction preserves existing NativeKit namespaces. Public `haxeon.gpu` namespaces are a subsequent API migration. Generated HXI and projection maps live in `bindings/`; managed code lives in `src/`.

## Native dependency

The supported NativeKit revision is recorded in `../nativekit.lock` and pinned in the package CI workflow. Check out NativeKit alongside Haxeon, or set `NATIVEKIT_DIR=/path/to/nativekit`. `HAXEON_DIR` may override the compiler checkout. Native libraries must be built and available on the runtime library search path; the package manifest does not build or bundle them.

## Tooling

Run tools from this package's `tools/` directory. Platform `tools/test-haxe-bindings.sh` performs ABI32/ABI64 checks and both platform and GPU runtime smoke tests. GPU `tools/check-hxi.sh` regenerates its reviewed interface; `tools/test-haxeon.sh` runs the graphical stress fixture.

Generator source labels retain their original paths to preserve reviewed HXI content during extraction.

## License

The extracted NativeKit bindings and wrappers retain their Apache License 2.0 license; see `LICENSE`.
