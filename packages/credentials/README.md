# Haxeon credentials package

This package exposes NativeKit's optional credentials module through the
`haxeon.credentials.Credentials` helper. Add `haxeon-credentials` as a Haxeon
dependency and build the package for the host target. The native module uses
the platform credential service; it does not store app state or fall back to
files.

Linux builds require the `libsecret-1` development package. The package's
`tests/haxeon.json` project exercises binary store, read, and delete through
the Haxe and NativeKit boundaries:

```sh
./scripts/haxeon run --project packages/credentials/tests/haxeon.json
```

The smoke test creates a unique credential and removes it even when an
assertion fails. A native module-level contract test is also available through
CTest when NativeKit is built with `NK_BUILD_CREDENTIALS=ON` and
`NK_BUILD_TESTS=ON`.
