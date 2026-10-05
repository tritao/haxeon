# Haxeon Audio Lab

Audio Lab is the first companion-app slice for NativeKit audio. It is a real
Haxeon desktop application, not a static UI mockup: preset buttons rebuild
NativeKit DSP patches, piano presses submit note events, and the cutoff slider
submits a sample-accurate parameter ramp into the same renderer used by audio
tests and the tracker model.

The current app includes:

- Synth Playground with subtractive, FM bell, drum, bass, pad, noise, and
  layered presets;
- virtual piano keyboard;
- oscilloscope and peak meter fed from rendered PCM frames;
- compact diagnostics for active voices, event count, frame position, and
  render timing;
- a compact tracker/sequencer screen with a playable 16-step pattern;
- a modulation matrix screen that describes the active preset's real routes.

Run the Haxeon app from the Haxeon root with:

```sh
./examples/audio-lab/tools/test-audio-lab.sh --run
```

Audio Lab currently renders into caller-owned PCM buffers for its oscilloscope,
meters, and diagnostics. It does not attach its engine to the playback device;
its controls produce offline PCM rather than audible output. The audio package
also provides device attachment and scheduling APIs for applications that need
playback.

The example namespace is `audiolab`. Its managed dependencies are
`haxeon.audio` and `haxeon.ui`; `CMakeLists.txt` builds one shared NativeKit
runtime with audio and GPU enabled, together with UI.

Build without launching the application:

```sh
./examples/audio-lab/tools/test-audio-lab.sh --build
```

Run the existing preset, automation, and tracker smoke check explicitly:

```sh
./examples/audio-lab/tools/test-audio-lab.sh --test
```

The previous NativeKit `tools/test-audio-lab.sh` is now this example-owned tool.
