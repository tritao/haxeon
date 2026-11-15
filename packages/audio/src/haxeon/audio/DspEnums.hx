package haxeon.audio;

/** Built-in oscillator and LFO shapes. */
typedef DspWaveform = nativekit.ffi.NativeKitAudioTypes.NativeDspWaveform;

/** Filter algorithms available to a DSP patch. */
typedef DspFilterType = nativekit.ffi.NativeKitAudioTypes.NativeDspFilterType;

/** LFO phase behavior when a voice receives a note-on. */
typedef DspLfoMode = nativekit.ffi.NativeKitAudioTypes.NativeDspLfoMode;

/** Sources available to a generic modulation route, including audio-rate operators. */
typedef DspModulationSource = nativekit.ffi.NativeKitAudioTypes.NativeDspModulationSource;

/** Destinations available to a generic modulation route. */
typedef DspModulationDestination = nativekit.ffi.NativeKitAudioTypes.NativeDspModulationDestination;

/** Normalizes a modulation source before its route amount is applied. */
typedef DspModulationPolarity = nativekit.ffi.NativeKitAudioTypes.NativeDspModulationPolarity;

/** Instrument parameters accepted by the native DSP instrument. */
typedef DspParameter = nativekit.ffi.NativeKitAudioTypes.NativeDspParameter;

/** Parameters of one oscillator source, addressed with its zero-based index. */
typedef DspOscillatorParameter = nativekit.ffi.NativeKitAudioTypes.NativeDspOscillatorParameter;
