# Haxeon audio

`haxeon-audio` provides `haxeon.audio.*`: clips and voices, mixer buses and effects,
spatial controls, resource-backed streaming, cues and banks, track playback,
and DSP patches, oscillators, envelopes, filters, modulation, and wavetables.
It depends on `haxeon-platform`; it has no UI or GPU dependency.

The native implementation remains in NativeKit `modules/audio`, backed by
pinned miniaudio, DaisySP, and Signalsmith submodules. Audio calls use the NativeKit UI thread;
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

Live synthesis can route through `DspEngine.setBus()` into the mixer graph.
`Bus.addReverb()` and `addDynamics()` provide stereo reverb and dynamics controls
through `haxeon.audio.EffectParameter`, with smoothed parameter changes, reset,
and latency/tail queries. Signalsmith Basics is pinned from the
[`tritao/signalsmith-basics`](https://github.com/tritao/signalsmith-basics) fork;
The DaisySP checkout stays pinned; NativeKit keeps small safety adaptations behind
its private backend. See the native guide for parameter ranges and routing.

`Bus.addSend(returnBus, gain)` routes a post-fader contribution to a shared
return, with up to eight sends per source and routing-cycle checks. Use wet-only
processors on returns; disconnecting a send preserves their existing tails.
`Bus.addStereoDelay()` exposes manual/tempo-synced delay, smoothed time changes,
and ping-pong feedback through `EffectParameter` and
`BusEffect.setDelayTempo(bpm, quarterNoteBeats)`. Its maximum delay is four seconds.
The miniaudio dependency is pinned to `tritao/miniaudio`'s `nativekit` branch,
based on upstream `dev`, with graph-clock synchronization fixes and regression tests.

## Specialized DaisySP sources

Set `DspPatchBuilder.source` to `new DspSourceOptions(DspSourceKind.Fm2)` or
another `DspSourceKind`. The 24 generators include physical strings and modal
voices, five drums, formant and spectral oscillators, noise textures, and granular
playback. They share the existing patch envelope, filter, modulation, mixer
routing, and score note lifecycle.

```haxe
var builder = new DspPatchBuilder();
builder.source = new DspSourceOptions(DspSourceKind.Fm2)
    .set(DspSourceParameter.Ratio, 3)
    .set(DspSourceParameter.Index, 7);
var patch = builder.build();
```

`set()` rejects unsupported controls and invalid domains before building.
`Sustain` is 0/1 on drums, StringVoice and ModalVoice; `SyncEnabled` is 0/1 on
VariableShape. Resonator resolution uses groups of four modes. `spectrum()`
normalizes seven bank registrations or sixteen harmonic weights.

Source-specific settings are immutable per patch; existing gain, envelope,
noise, filter, oscillator level/detune, and compatible modulation routes remain
available. Replacement sources require the builder's single default oscillator
slot and use its level/detune. KarplusString and Resonator accept the oscillator
and noise graph as excitation. Sources with their own decay may fall silent
while an ADSR gate is held; use Sustain where available for held tones.

Granular playback copies finite mono PCM from `source.samples` when building a
patch. Supply PCM at the engine sample rate, set `RootNote` to its original MIDI
pitch, and choose `Speed` and `GrainMs`. Destroying the patch or replacing the
caller’s sample array does not invalidate an existing instrument. This is PCM
granulation; SoundFont/SF2 loading is a separate feature.

Callback telemetry is opt-in through `Mixer.setDiagnosticsEnabled(true)` and
`Mixer.diagnostics()`. Collection uses lock-free atomic counters and monotonic
clock samples, with no callback logging or allocation. Read snapshots on the
application thread. Counts/maxima are cumulative for the engine lifetime and
survive disabling collection. Callback gaps and render budget overruns are
observations rather than backend/hardware XRUN reports. Disabling collection
removes timestamp sampling; the disabled branch remains in the callback.

## Stereo unison and filter envelopes

`DspPatchBuilder.unison` configures 1–8 detuned copies of each built-in oscillator
or wavetable. `detuneCents` is the maximum deviation on either side (0–100 cents);
`stereoSpread` pans copies from the center towards left/right (0–1). Copy gains
are normalized by count with constant-sum panning. Each copy retains its own
FM/phase-modulation operator graph. A single copy remains centered.

`filterEnvelope` is an independent ADSR, sharing the note gate with `envelope`.
`filterEnvelopeAmountSemitones` sweeps cutoff by `2^(level * amount / 12)` before
existing cutoff-Hz modulation is added and the cutoff is clamped. Its range is
−96 to +96 semitones; zero preserves the original filter behavior. Amplitude
release determines voice lifetime, even if filter release is longer.

```haxe
var patch = new DspPatchBuilder();
patch.oscillators[0].waveform = DspWaveform.Saw;
patch.unison.count = 5;
patch.unison.detuneCents = 12;
patch.unison.stereoSpread = 0.9;
patch.filter.type = DspFilterType.SvfLowPass;
patch.filter.cutoffHz = 550;
patch.filterEnvelope.attackSeconds = 1.2;
patch.filterEnvelopeAmountSemitones = 30;
patch.envelope.attackSeconds = 0.6;
```

Defaults preserve centered single-copy synthesis with no filter sweep. Specialized
Daisy sources support the independent filter envelope and reject more than one
unison copy. Stereo rendering preserves L/R; mono averages them. These controls
are immutable patch settings, rebuilt between auditions rather than automated
through the instrument parameter API.
