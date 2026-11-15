package haxeon.audio;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** One sample-accurate operation applied during a DSP render block. */
class DspEvent {
	final kind:DspEventKind;
	/** Sample offset used to merge/sort events before rendering or scheduling. */
	public final frameOffset:Int;
	final instrument:Null<DspInstrument>;
	final voiceId:Int;
	final note:Int;
	final velocity:Float;
	final parameterValue:Null<DspParameter>;
	final oscillatorParameterValue:Null<DspOscillatorParameter>;
	final oscillatorIndex:Int;
	final value:Float;
	final endValue:Float;
	final durationFrames:Int;

	private function new(kind:DspEventKind, frameOffset:Int, instrument:Null<DspInstrument>, voiceId:Int, note:Int, velocity:Float,
			?parameter:DspParameter, ?oscillatorParameter:DspOscillatorParameter, value:Float = 0.0, oscillatorIndex:Int = 0,
			endValue:Float = 0.0, durationFrames:Int = 0) {
		if (frameOffset < 0)
			throw BindingError.invalidArgument("DspEvent.new", "DSP event frame offset must not be negative");
		this.kind = kind;
		this.frameOffset = frameOffset;
		this.instrument = instrument;
		this.voiceId = voiceId;
		this.note = note;
		this.velocity = velocity;
		this.parameterValue = parameter;
		this.oscillatorParameterValue = oscillatorParameter;
		this.oscillatorIndex = oscillatorIndex;
		this.value = value;
		this.endValue = endValue;
		this.durationFrames = durationFrames;
	}

	/** Starts a voice at an inclusive MIDI note and normalized velocity.
	 * Reusing a sounding identity restarts its note and retriggered LFO phases
	 * through a five-millisecond stereo continuity bridge. It replaces that
	 * voice; use distinct identities for notes that should overlap.
	 */
	public static function noteOn(instrument:DspInstrument, voiceId:Int, note:Int,
		velocity:Float = 1.0, frameOffset:Int = 0):DspEvent {
		if (instrument == null)
			throw BindingError.invalidArgument("DspEvent.noteOn", "DSP note-on instrument must not be null");
		return new DspEvent(DspEventKind.NoteOn, frameOffset, instrument,
			voiceId, note, velocity);
	}

	/** Releases a voice identity at an exact frame offset. */
	public static function noteOff(voiceId:Int, frameOffset:Int = 0):DspEvent
		return new DspEvent(DspEventKind.NoteOff, frameOffset, null,
			voiceId, 0, 0.0);

	/** Changes an instrument parameter at an exact frame offset. */
	public static function parameter(instrument:DspInstrument, parameter:DspParameter, value:Float, frameOffset:Int = 0):DspEvent {
		if (instrument == null)
			throw BindingError.invalidArgument("DspEvent.parameter", "DSP parameter instrument must not be null");
		return new DspEvent(DspEventKind.Parameter, frameOffset, instrument, 0, 0, 0.0, parameter, null, value);
	}

	/** Changes one parameter of an oscillator source at an exact frame offset. */
	public static function oscillatorParameter(instrument:DspInstrument, oscillatorIndex:Int, parameter:DspOscillatorParameter, value:Float,
			frameOffset:Int = 0):DspEvent {
		if (instrument == null)
			throw BindingError.invalidArgument("DspEvent.oscillatorParameter", "DSP oscillator parameter instrument must not be null");
		if (oscillatorIndex < 0)
			throw BindingError.invalidArgument("DspEvent.oscillatorParameter", "DSP oscillator parameter index must not be negative");
		return new DspEvent(DspEventKind.OscillatorParameter, frameOffset, instrument, 0, 0, 0.0, null, parameter, value, oscillatorIndex);
	}

	/** Linearly changes an instrument parameter over exact audio frames. */
	public static function parameterRamp(instrument:DspInstrument, parameter:DspParameter, startValue:Float, endValue:Float, durationFrames:Int,
			frameOffset:Int = 0):DspEvent {
		if (instrument == null)
			throw BindingError.invalidArgument("DspEvent.parameterRamp", "DSP parameter ramp instrument must not be null");
		validateRampDuration(durationFrames);
		if (parameter == DspParameter.Waveform)
			throw BindingError.invalidArgument("DspEvent.parameterRamp", "DSP parameter ramp cannot target a waveform");
		return new DspEvent(DspEventKind.ParameterRamp, frameOffset, instrument, 0, 0, 0.0, parameter, null, startValue, 0, endValue,
			durationFrames);
	}

	/** Linearly changes one parameter of an oscillator source over exact audio frames. */
	public static function oscillatorParameterRamp(instrument:DspInstrument, oscillatorIndex:Int, parameter:DspOscillatorParameter,
			startValue:Float, endValue:Float, durationFrames:Int, frameOffset:Int = 0):DspEvent {
		if (instrument == null)
			throw BindingError.invalidArgument("DspEvent.oscillatorParameterRamp", "DSP oscillator parameter ramp instrument must not be null");
		if (oscillatorIndex < 0)
			throw BindingError.invalidArgument("DspEvent.oscillatorParameterRamp", "DSP oscillator parameter ramp index must not be negative");
		if (parameter == DspOscillatorParameter.Waveform)
			throw BindingError.invalidArgument("DspEvent.oscillatorParameterRamp", "DSP parameter ramp cannot target a waveform");
		validateRampDuration(durationFrames);
		return new DspEvent(DspEventKind.OscillatorParameterRamp, frameOffset, instrument, 0, 0, 0.0, null, parameter, startValue,
			oscillatorIndex, endValue, durationFrames);
	}

	static function validateRampDuration(durationFrames:Int):Void {
		if (durationFrames <= 0)
			throw BindingError.invalidArgument("DspEvent.validateRampDuration", "DSP parameter ramp duration must be positive");
	}

	@:allow(haxeon.audio.DspEngine)
	private function nativeValue():NativeDspEvent {
		var result = new NativeDspEvent();
		result.set_struct_size(NativeDspEvent.size());
		result.set_kind(kind);
		result.set_frame_offset(frameOffset);
		result.set_instrument(instrument == null ? DspInstrumentHandle.invalid() : instrument.nativeHandle());
		result.set_voice_id(voiceId);
		result.set_note(note);
		result.set_velocity(velocity);
		// Each kind reads only its own parameter field; the other stays zero.
		if (parameterValue != null)
			result.set_parameter(parameterValue);
		if (oscillatorParameterValue != null)
			result.set_oscillator_parameter(oscillatorParameterValue);
		result.set_oscillator_index(oscillatorIndex);
		result.set_value(value);
		result.set_end_value(endValue);
		result.set_duration_frames(durationFrames);
		return result;
	}
}
