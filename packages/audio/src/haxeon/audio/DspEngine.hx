package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.audio.DspTransport;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitException;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/** Owns a standalone native DSP renderer and its instruments. */
class DspEngine implements Disposable {
	final value:DspEngineHandle;
	final owned:OwnedDspEngineHandle;
	final instruments:Array<DspInstrument> = [];
	var disposed:Bool = false;
	var deviceAttached:Bool = false;

	private function new(owned:OwnedDspEngineHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	/** A renderer configured by `options`, or the defaults. */
	public static function create(?options:DspEngineOptions):DspEngine {
		var actual = options == null ? new DspEngineOptions() : options;
		var made = NativeKitAudio.nk_audio_dsp_engine_create(actual.nativeValue());
		AudioResult.check(made.status, "audio.dsp.engine.create");
		return new DspEngine(made.out_engine);
	}

	internal function nativeHandle():DspEngineHandle {
		ensureLive();
		return value;
	}

	/** Creates an instrument that copies the supplied immutable patch. */
	public function createInstrument(patch:DspPatch):DspInstrument {
		ensureLive();
		if (patch == null)
			throw BindingError.invalidArgument("DspEngine.createInstrument", "DSP patch must not be null");
		var made = NativeKitAudio.nk_audio_dsp_instrument_create_from_patch(value,
			patch.nativeHandle());
		AudioResult.check(made.status, "audio.dsp.instrument.create");
		var result = new DspInstrument(made.out_instrument);
		instruments.push(result);
		return result;
	}

	@:allow(haxeon.audio.SampleInstrument)
	private function createSampleInstrument(options:NativeDspSampleOptions, samples:Array<Float>):DspInstrument {
		ensureLive();
		var made = NativeKitAudio.nk_audio_dsp_instrument_create_from_sample(value, options, samples);
		AudioResult.check(made.status, "audio.dsp.instrument.sample");
		var result = new DspInstrument(made.out_instrument);
		instruments.push(result);
		return result;
	}

	internal function createSoundFontInstrument(font:SoundFont, preset:Int, gain:Float = 1.0):DspInstrument {
		ensureLive();
		if (font == null) throw BindingError.invalidArgument("DspEngine.createSoundFontInstrument",
			"SoundFont must not be null");
		var made = NativeKitAudio.nk_audio_dsp_instrument_create_from_soundfont(value,
			font.nativeHandle(), preset, gain);
		AudioResult.check(made.status, "audio.dsp.instrument.soundfont");
		var result = new DspInstrument(made.out_instrument);
		instruments.push(result);
		return result;
	}

	/** Configure bounded voice stealing before attachment or playback. */
	public function setVoicePolicy(tailVoices:Int = 8, fadeFrames:Int = 240):Void {
		ensureLive();
		var policy = new NativeDspVoicePolicyOptions();
		policy.struct_size = NativeDspVoicePolicyOptions.byteSize();
		policy.steal_enabled = 1;
		policy.tail_voices = tailVoices;
		policy.fade_frames = fadeFrames;
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_set_voice_policy(value, policy),
			"audio.dsp.engine.voicePolicy");
	}

	/** Native identity and release deadline; no application-thread note-off pumping. */
	public function noteOn(instrument:DspInstrument, note:Int, velocity:Float,
			startFrame:Int64, holdFrames:Int64, priority:Int = 0):Int64 {
		var token = tryNoteOn(instrument, note, velocity, startFrame, holdFrames, priority);
		if (token == null) throw new NativeKitException(Busy, "audio.dsp.engine.noteOn",
			NativeResult.ErrorQueueFull.rawValue);
		return cast token;
	}
	/** Ordinary overload admission: null means the bounded ingress queue is full. */
	public function tryNoteOn(instrument:DspInstrument, note:Int, velocity:Float,
			startFrame:Int64, holdFrames:Int64, priority:Int = 0):Null<Int64> {
		ensureLive();
		if (instrument == null) throw BindingError.invalidArgument("DspEngine.tryNoteOn",
			"DSP note instrument must not be null");
		var options = new NativeDspNoteOptions();
		options.struct_size = NativeDspNoteOptions.byteSize();
		options.note = note;
		options.velocity = velocity;
		options.start_frame = startFrame;
		options.hold_frames = holdFrames;
		options.priority = priority;
		var result = NativeKitAudio.nk_audio_dsp_engine_note_on(value, instrument.nativeHandle(), options);
		if (result.status == NativeResult.ErrorQueueFull) return null;
		AudioResult.check(result.status, "audio.dsp.engine.noteOn");
		return result.out_note_token;
	}

	/** Releases note `token` at `frame`. */
	public function noteOff(token:Int64, frame:Int64):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_note_off(value, token, frame),
			"audio.dsp.engine.noteOff");
	}

	/** Validates and copies a score of `sections`, ready to play without changing what sounds. */
	public function prepareTransport(sections:Array<DspTransportSection>):DspTransport {
		ensureLive();
		var nativeSections:Array<NativeDspTransportSection> = [];
		var nativeEvents:Array<NativeDspTransportEvent> = [];
		var bars:Array<Float> = [];
		for (section in sections) {
			var prepared = new NativeDspTransportSection();
			prepared.length_frames = section.lengthFrames;
			prepared.event_offset = nativeEvents.length;
			prepared.event_count = section.events.length;
			prepared.bar_offset = bars.length;
			prepared.bar_count = section.bars.length;
			nativeSections.push(prepared);
			for (event in section.events) {
				var item = new NativeDspTransportEvent();
				item.frame = event.frame;
				item.kind = event.kind.rawValue;
				item.note_id = event.noteId;
				item.instrument = event.instrument == null
					? DspInstrumentHandle.invalid() : event.instrument.nativeHandle();
				item.note = event.note;
				item.velocity = event.velocity;
				item.bpm = event.bpm;
				nativeEvents.push(item);
			}
			for (bar in section.bars) bars.push(bar);
		}
		var result = NativeKitAudio.nk_audio_dsp_engine_prepare_transport(value, nativeSections, nativeEvents, bars);
		AudioResult.check(result.status, "audio.dsp.transport.prepare");
		return new DspTransport(this, result.out_program_id);
	}

	/** Moves the playing score to `section` at its next bar. */
	public function requestSection(section:Int):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_request_section(value, section),
			"audio.dsp.transport.requestSection");
	}

	/** Stops the playing score. */
	public function stopTransport():Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_stop_transport(value), "audio.dsp.transport.stop");
	}
	/** Coherent section-local playhead from the last native render block. */
	public function transportPosition():{section:Int, frame:Float} {
		ensureLive();
		var result = NativeKitAudio.nk_audio_dsp_engine_get_transport_position(value);
		AudioResult.check(result.status, "audio.dsp.transport.position");
		return {section: result.out_section, frame: result.out_frame};
	}

	/** A consistent snapshot of the playing score and the engine's counters. */
	public function runtimeStatus():DspRuntimeStatus {
		ensureLive();
		var status = new NativeDspRuntimeStatus();
		status.struct_size = NativeDspRuntimeStatus.byteSize();
		var result = NativeKitAudio.nk_audio_dsp_engine_get_runtime_status(value, status);
		AudioResult.check(result.status, "audio.dsp.runtime.status");
		status = result.out_status;
		return {
			playing: status.playing != 0,
			section: status.section,
			frame: status.frame,
			loops: status.loops,
			bpm: status.bpm,
			stolenVoices: status.stolen_voices,
			droppedNotes: status.dropped_notes,
			retiredResources: status.retired_resources,
			clockDiscontinuities: status.clock_discontinuities
		};
	}
	/** Last completed block's occupied note slots and stealing tails, including releases. */
	public function voiceCounts():{activeVoices:Int, activeTails:Int} {
		ensureLive();
		var result = NativeKitAudio.nk_audio_dsp_engine_get_voice_counts(value);
		AudioResult.check(result.status, "audio.dsp.voiceCounts");
		return {activeVoices: result.out_active_voices, activeTails: result.out_active_tails};
	}

	/** Reclaims resources the audio thread has finished with; call it regularly off that thread. */
	public function collect():Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_collect(value), "audio.dsp.engine.collect");
		var index = instruments.length;
		while (index > 0) {
			--index;
			if (instruments[index].isDisposed()) instruments.splice(index, 1);
		}
	}

	/** Returns instruments and voices to their starting state. Detach from the device first. */
	public function reset():Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_reset(value), "audio.dsp.engine.reset");
	}

	/** Routes this renderer into the process-wide NativeKit playback device, or answers why the device cannot take it. */
	public function attachToDevice():Result<Void, NativeKitError> {
		ensureLive();
		if (deviceAttached)
			return Ok();
		try NativeKitStatus.result(NativeKitAudio.nk_audio_dsp_engine_attach_device(value),
			"audio.dsp.engine.attachDevice",
			NativeKit.nk_last_error());
		deviceAttached = true;
		return Ok();
	}

	/** Routes live output through a bus, or directly to master when null.
	 * Attach to the device first. Destroying the bus restores master routing. */
	public function setBus(bus:Null<Bus>):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_set_bus(value,
			bus == null ? BusHandle.invalid() : bus.nativeHandle()), "audio.dsp.engine.setBus");
	}

	/** Stops routing this renderer into the process-wide NativeKit playback device. */
	public function detachFromDevice():Void {
		ensureLive();
		if (!deviceAttached)
			return;
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_detach_device(value),
			"audio.dsp.engine.detachDevice");
		deviceAttached = false;
	}

	/** Queues block-local events against an absolute playback-device frame. */
	public function schedule(startFrame:haxe.Int64, ?events:Array<DspEvent>):Void {
		ensureLive();
		var nativeEvents:Array<NativeDspEvent> = [];
		if (events != null) {
			var previousFrame = 0;
			for (event in events) {
				if (event == null)
					throw BindingError.invalidArgument("DspEngine.schedule", "DSP scheduled event must not be null");
				if (event.frameOffset < previousFrame)
					throw BindingError.invalidArgument("DspEngine.schedule",
						"DSP scheduled events must be sorted by frame offset");
				previousFrame = event.frameOffset;
				nativeEvents.push(event.nativeValue());
			}
		}
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_schedule(value, startFrame,
			nativeEvents), "audio.dsp.engine.schedule");
	}

	/** Drops queued events and resets active voices at the next audio block. */
	public function clearSchedule():Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_clear_schedule(value),
			"audio.dsp.engine.clearSchedule");
	}

	/** What the renderer's backend supports. */
	public function capabilities():DspCapabilities {
		ensureLive();
		var result = NativeKitAudio.nk_audio_dsp_engine_get_capabilities(value);
		AudioResult.check(result.status, "audio.dsp.engine.capabilities");
		return result.out_capabilities;
	}

	/** Renders one block into the supplied target and applies sorted events. */
	public function render(target:DspRenderTarget, ?events:Array<DspEvent>):Bytes {
		ensureLive();
		if (target == null)
			throw BindingError.invalidArgument("DspEngine.render", "DSP render target must not be null");
		var nativeEvents:Array<NativeDspEvent> = [];
		if (events != null) {
			var previousFrame = 0;
			for (event in events) {
				if (event == null)
					throw BindingError.invalidArgument("DspEngine.render", "DSP render event must not be null");
				if (event.frameOffset < previousFrame)
					throw BindingError.invalidArgument("DspEngine.render",
						"DSP render events must be sorted by frame offset");
				previousFrame = event.frameOffset;
				nativeEvents.push(event.nativeValue());
			}
		}
		var status = NativeKitAudio.nk_audio_dsp_engine_render_buffer(value, target.samples,
			target.frameCount, target.channels, nativeEvents);
		AudioResult.check(status, "audio.dsp.engine.render");
		return target.samples;
	}

	public function dispose():Void {
		if (disposed)
			return;
		var failure:Dynamic = null;
		if (deviceAttached) {
			try {
				AudioResult.check(NativeKitAudio.nk_audio_dsp_engine_detach_device(value),
					"audio.dsp.engine.detachDevice");
				deviceAttached = false;
			} catch (error:Dynamic) {
				failure = error;
			}
		}
		if (failure != null)
			throw failure;
		for (index in 0...instruments.length) {
			var instrument = instruments[instruments.length - 1 - index];
			try {
				instrument.dispose();
			} catch (error:Dynamic) {
				if (failure == null)
					failure = error;
			}
		}
		if (failure != null)
			throw failure;
		instruments.resize(0);
		var status = owned.close();
		disposed = true;
		if (status != null && status != NativeResult.Ok)
			throw NativeKitStatus.failure(status, "audio.dsp.engine.dispose", NativeKit.nk_last_error());
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("DspEngine.ensureLive", "DSP engine has been disposed");
	}
}
