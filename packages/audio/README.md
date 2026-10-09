# Haxeon audio

`haxeon-audio` provides `haxeon.audio.*`: clips and voices, mixer buses and effects,
spatial controls, resource-backed streaming, cues and banks, track playback,
and DSP patches, oscillators, envelopes, filters, modulation, and wavetables.
It depends on `haxeon-platform`; it has no UI or GPU dependency.

The native implementation remains in NativeKit `modules/audio`, backed by
pinned miniaudio and DaisySP submodules. Audio calls use the NativeKit UI thread;
the playback callback and streaming workers are internal to the native backend.
The C ABI and library name (`nativekit`) stay unchanged. Raw generated bindings
live in `nativekit.ffi.NativeKitAudio` and `NativeKitAudioTypes`.

Initialize dependencies from the Haxeon root:

```sh
git submodule update --init --recursive vendor/nativekit
```

Use a path dependency on this package in `haxeon.json`. For a headless audio
application, also depend on `packages/audio/native` (`haxeon-audio-native`),
whose CMake provider builds NativeKit with `NK_BUILD_AUDIO=ON`.
Applications combining UI and audio should use one native provider that builds
NativeKit with audio and GPU enabled, plus UI. Audio Lab demonstrates this
composition in `examples/audio-lab/CMakeLists.txt`; its managed dependency on
`haxeon-audio` does not introduce a second core runtime.

To run the existing native and managed coverage:

```sh
./packages/audio/tools/test-haxeon.sh
```

Tools accept `NATIVEKIT_DIR`, `HAXEON_DIR`, and `NATIVEKIT_BUILD_DIR` overrides.
Audio device tests can skip when no device is available; DSP rendering also has
offline coverage. Browser playback and Windows/macOS devices need separate
runtime qualification. The native API guide is in NativeKit `modules/audio/README.md`.
