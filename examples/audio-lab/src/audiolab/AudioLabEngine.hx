package audiolab;

import haxe.io.Bytes;
import haxeon.audio.DspEngine;
import haxeon.audio.Bus;
import haxeon.audio.BusEffect;
import haxeon.audio.BusSend;
import haxeon.audio.DeviceOptions;
import haxeon.audio.Mixer;
import nativekit.ffi.NativeKitAudioTypes.EffectParameter;
import haxeon.audio.DspEngineOptions;
import haxeon.audio.DspEnums.DspParameter;
import haxeon.audio.DspEvent;
import haxeon.audio.DspInstrument;
import haxeon.audio.DspPatch;
import haxeon.audio.DspPatchBuilder;
import haxeon.audio.DspRenderTarget;

private class PendingNote {
	public final voiceId:Int;
	public final note:Int;
	public final velocity:Float;

	public function new(voiceId:Int, note:Int, velocity:Float) {
		this.voiceId = voiceId;
		this.note = note;
		this.velocity = velocity;
	}
}

private class ActiveVoice {
	public final voiceId:Int;
	public final releaseFrame:Int;

	public function new(voiceId:Int, releaseFrame:Int) {
		this.voiceId = voiceId;
		this.releaseFrame = releaseFrame;
	}
}

/** Small stateful host used by the Audio Lab screens and diagnostics. */
class AudioLabEngine {
	public static inline var SAMPLE_RATE:Int = 48000;
	public static inline var BLOCK_SIZE:Int = 256;
	public static inline var CHANNELS:Int = 2;
	public static inline var MAX_VOICES:Int = 32;

	public final dsp:DspEngine;
	public var patch(default, null):DspPatch;
	public var instrument(default, null):DspInstrument;
	public var preset(default, null):AudioLabPresetId;
	public var filterCutoff(default, null):Float;
	public var frame(default, null):Int = 0;
	public var eventCount(default, null):Int = 0;
	public var lastBlockEventCount(default, null):Int = 0;
	public var activeVoices(default, null):Int = 0;
	public var peak(default, null):Float = 0.0;
	public var rms(default, null):Float = 0.0;
	public var renderMilliseconds(default, null):Float = 0.0;
	public var trackerPlaying:Bool = false;
	public var trackerStep(default, null):Int = 0;
	public final scope:Array<Float> = [];

	public var playbackStatus(default, null):String = "Offline preview";
	public var reverbWet(default, null):Float = 0.15;
	public var reverbDecay(default, null):Float = 3.0;
	public var compressionRatio(default, null):Float = 1.0;
	var liveDsp:Null<DspEngine> = null;
	var liveInstrument:Null<DspInstrument> = null;
	var musicBus:Null<Bus> = null;
	var roomBus:Null<Bus> = null;
	var delayBus:Null<Bus> = null;
	var roomSend:Null<BusSend> = null;
	var stereoDelay:Null<BusEffect> = null;
	var reverb:Null<BusEffect> = null;
	var dynamics:Null<BusEffect> = null;
	var nextLiveFrame:haxe.Int64 = haxe.Int64.ofInt(0);
	static inline var LOOKAHEAD:Int = 4800;

	final target:DspRenderTarget;
	final pendingNotes:Array<PendingNote> = [];
	final active:Array<ActiveVoice> = [];
	var nextVoiceId:Int = 1;
	var appliedFilterCutoff:Float = 0.0;
	var pendingFilter:Null<Float> = null;
	var elapsed:Float = 0.0;
	var trackerClock:Float = 0.0;
	var trackerNotes:Array<Int> = [48, 48, 55, 60, 48, 48, 55, 62, 43, 43, 50, 55, 45, 45, 52, 57];

	public function new(playback:Bool = false) {
		var options = new DspEngineOptions();
		options.sampleRate = SAMPLE_RATE;
		options.channels = CHANNELS;
		options.blockSize = BLOCK_SIZE;
		options.maxVoices = MAX_VOICES;
		dsp = DspEngine.create(options);
		target = new DspRenderTarget(BLOCK_SIZE, CHANNELS);
		for (_ in 0...64)
			scope.push(0.0);
		if (playback) {
			try {
				var device = new DeviceOptions();
				device.sampleRate = SAMPLE_RATE;
				device.channels = CHANNELS;
				Mixer.configureDevice(device);
				musicBus = Bus.create();
				musicBus.setVolume(0.35);
				roomBus = Bus.create();
				reverb = roomBus.addReverb();
				reverb.setParameter(EffectParameter.Dry, 0.0);
				reverb.setParameter(EffectParameter.Wet, 1.0);
				roomSend = musicBus.addSend(roomBus, reverbWet);
				delayBus = Bus.create();
				stereoDelay = delayBus.addStereoDelay();
				stereoDelay.setParameter(EffectParameter.Dry, 0.0);
				stereoDelay.setParameter(EffectParameter.Wet, 1.0);
				stereoDelay.setParameter(EffectParameter.PingPong, 1.0);
				stereoDelay.setDelayTempo(120.0, 0.5);
				musicBus.addSend(delayBus, 0.1);
				dynamics = musicBus.addDynamics();
				liveDsp = DspEngine.create(options);
				playbackStatus = "Live playback • monitor shows dry synth";
			} catch (error:Dynamic) {
				if (liveDsp != null) liveDsp.dispose();
				liveDsp = null;
				if (musicBus != null) musicBus.dispose();
				if (roomBus != null) roomBus.dispose();
				if (delayBus != null) delayBus.dispose();
				musicBus = null;
				roomBus = null;
				delayBus = null;
				roomSend = null;
				stereoDelay = null;
				reverb = null;
				dynamics = null;
				playbackStatus = "Playback unavailable: " + Std.string(error);
			}
		}
		selectPreset(AudioLabPreset.Subtractive);
	}

	public function selectPreset(next:AudioLabPresetId):Void {
		// Detach before replacing live instruments so the callback has stopped using them.
		if (liveDsp != null) liveDsp.detachFromDevice();
		if (liveInstrument != null) liveInstrument.dispose();
		if (instrument != null)
			instrument.dispose();
		if (patch != null)
			patch.dispose();
		dsp.reset();
		var builder:DspPatchBuilder = AudioLabPreset.build(next);
		patch = builder.build();
		instrument = dsp.createInstrument(patch);
		if (liveDsp != null) {
			liveInstrument = liveDsp.createInstrument(patch);
			liveDsp.attachToDevice();
			liveDsp.setBus(musicBus);
			nextLiveFrame = haxe.Int64.add(Mixer.timeFrames(), haxe.Int64.ofInt(LOOKAHEAD));
			if (reverb != null) reverb.reset();
			if (stereoDelay != null) stereoDelay.reset();
		}
		patch.dispose();
		preset = next;
		filterCutoff = builder.filter.cutoffHz;
		appliedFilterCutoff = filterCutoff;
		pendingFilter = null;
		pendingNotes.resize(0);
		active.resize(0);
		activeVoices = 0;
		trackerStep = 0;
		eventCount = 0;
		lastBlockEventCount = 0;
	}

	/** Queues a short piano note; the actual NOTE_ON is applied at a render boundary. */
	public function noteOn(note:Int, velocity:Float = 0.9):Void {
		// Reuse a bounded pool, including voices still in their release tail.
		// Retriggering an existing native voice replaces it without exceeding
		// polyphony. Cancel its old pending start/release so neither can affect
		// the replacement note later in the block.
		var voiceId = nextVoiceId;
		nextVoiceId = nextVoiceId % MAX_VOICES + 1;
		var index = pendingNotes.length;
		while (index > 0) {
			index--;
			if (pendingNotes[index].voiceId == voiceId) pendingNotes.splice(index, 1);
		}
		index = active.length;
		while (index > 0) {
			index--;
			if (active[index].voiceId == voiceId) active.splice(index, 1);
		}
		pendingNotes.push(new PendingNote(voiceId, note, clamp(velocity, 0.0, 1.0)));
		active.push(new ActiveVoice(voiceId, frame + Std.int(SAMPLE_RATE * 0.42)));
		activeVoices = active.length;
	}

	public function setFilterCutoff(value:Float):Void {
		var bounded = clamp(value, 80.0, 18000.0);
		filterCutoff = bounded;
		pendingFilter = bounded;
	}

	public function setReverbWet(value:Float):Void {
		reverbWet = clamp(value, 0.0, 1.0);
		if (roomSend != null) roomSend.setVolume(reverbWet);
	}

	public function setReverbDecay(value:Float):Void {
		reverbDecay = clamp(value, 0.1, 10.0);
		if (reverb != null) reverb.setParameter(EffectParameter.DecaySeconds, reverbDecay);
	}

	public function setCompressionRatio(value:Float):Void {
		compressionRatio = clamp(value, 1.0, 10.0);
		if (dynamics != null) {
			dynamics.setParameter(EffectParameter.ThresholdDb, -20.0);
			dynamics.setParameter(EffectParameter.Ratio, compressionRatio);
		}
	}

	public function toggleTracker():Void {
		trackerPlaying = !trackerPlaying;
		if (trackerPlaying)
			trackerClock = 0.0;
	}

	/** Advances the renderer in fixed-size blocks and updates visual diagnostics. */
	public function advance(deltaSeconds:Float):Void {
		if (deltaSeconds < 0.0)
			deltaSeconds = 0.0;
		elapsed += Math.min(deltaSeconds, 0.1);
		if (liveDsp != null) {
			var minimumFrame = haxe.Int64.add(Mixer.timeFrames(), haxe.Int64.ofInt(BLOCK_SIZE * 2));
			if (haxe.Int64.compare(nextLiveFrame, minimumFrame) < 0)
				nextLiveFrame = haxe.Int64.add(Mixer.timeFrames(), haxe.Int64.ofInt(LOOKAHEAD));
		}
		var blockSeconds = BLOCK_SIZE / SAMPLE_RATE;
		var guard = 0;
		while (elapsed >= blockSeconds && guard++ < 12) {
			if (trackerPlaying) {
				trackerClock -= blockSeconds;
				if (trackerClock <= 0.0) {
					noteOn(trackerNotes[trackerStep], 0.72);
					trackerStep = (trackerStep + 1) % trackerNotes.length;
					trackerClock += 0.125;
				}
			}
			renderBlock();
			elapsed -= blockSeconds;
		}
		if (frame == 0)
			renderBlock();
	}

	function renderBlock():Void {
		var startedAt = Sys.cpuTime();
		var events:Array<DspEvent> = [];
		var liveEvents:Array<DspEvent> = [];
		for (note in pendingNotes) {
			events.push(DspEvent.noteOn(instrument, note.voiceId, note.note, note.velocity, 0));
			if (liveInstrument != null)
				liveEvents.push(DspEvent.noteOn(liveInstrument, note.voiceId, note.note, note.velocity, 0));
		}
		pendingNotes.resize(0);

		var survivors:Array<ActiveVoice> = [];
		for (voice in active) {
			if (voice.releaseFrame < frame + BLOCK_SIZE) {
				var offset = Std.int(Math.max(0, voice.releaseFrame - frame));
				events.push(DspEvent.noteOff(voice.voiceId, offset));
				if (liveDsp != null) liveEvents.push(DspEvent.noteOff(voice.voiceId, offset));
			} else {
				survivors.push(voice);
			}
		}
		active.resize(0);
		for (voice in survivors)
			active.push(voice);

		if (pendingFilter != null) {
			var targetFilter:Float = pendingFilter;
			events.push(DspEvent.parameterRamp(instrument, DspParameter.FilterCutoffHz,
				appliedFilterCutoff, targetFilter, BLOCK_SIZE, 0));
			if (liveInstrument != null)
				liveEvents.push(DspEvent.parameterRamp(liveInstrument, DspParameter.FilterCutoffHz,
					appliedFilterCutoff, targetFilter, BLOCK_SIZE, 0));
			appliedFilterCutoff = targetFilter;
			pendingFilter = null;
		}
		lastBlockEventCount = events.length;
		eventCount += events.length;
		events.sort(function(a, b) return a.frameOffset - b.frameOffset);
		dsp.render(target, events);
		if (liveDsp != null) {
			liveEvents.sort(function(a, b) return a.frameOffset - b.frameOffset);
			if (liveEvents.length > 0) liveDsp.schedule(nextLiveFrame, liveEvents);
			nextLiveFrame = haxe.Int64.add(nextLiveFrame, haxe.Int64.ofInt(BLOCK_SIZE));
		}
		var total:Float = 0.0;
		var highest:Float = 0.0;
		var scopeLength = scope.length;
		for (index in 0...BLOCK_SIZE) {
			var sample = floatFromBits(target.samples.getInt32(index * CHANNELS * 4));
			var magnitude = Math.abs(sample);
			if (magnitude > highest)
				highest = magnitude;
			total += sample * sample;
			var scopeIndex = Std.int(index * scopeLength / BLOCK_SIZE);
			if (scopeIndex < scopeLength)
				scope[scopeIndex] = sample;
		}
		peak = highest;
		rms = Math.pow(total / BLOCK_SIZE, 0.5);
		renderMilliseconds = (Sys.cpuTime() - startedAt) * 1000.0;
		frame += BLOCK_SIZE;
		activeVoices = active.length;
	}

	public function dispose():Void {
		if (liveDsp != null) liveDsp.dispose();
		if (musicBus != null) musicBus.dispose();
		if (roomBus != null) roomBus.dispose();
		if (delayBus != null) delayBus.dispose();
		if (instrument != null)
			instrument.dispose();
		if (patch != null)
			patch.dispose();
		dsp.dispose();
	}

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float
		return value < minimum ? minimum : value > maximum ? maximum : value;

	/** Haxeon exposes the PCM buffer's integer view; decode its IEEE-754 words. */
	static function floatFromBits(bits:Int):Float {
		var sign = 1 - ((bits >>> 31) << 1);
		var exponent = (bits >>> 23) & 0xff;
		if (exponent == 255)
			return 0.0;
		var mantissa = exponent == 0 ? (bits & 0x7fffff) << 1 : (bits & 0x7fffff) | 0x800000;
		return sign * mantissa * Math.pow(2.0, exponent - 150);
	}
}
