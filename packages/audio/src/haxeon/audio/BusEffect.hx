package haxeon.audio;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import haxeon.platform.NativeKitError;

/** One processing node in a mixer bus's ordered effect chain. */
class BusEffect {
	final value:BusEffectHandle;
	final owned:OwnedBusEffectHandle;
	var disposed:Bool = false;

	@:allow(haxeon.audio.Bus)
	private function new(owned:OwnedBusEffectHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	public function nativeHandle():BusEffectHandle {
		ensureLive();
		return value;
	}

	public function type():EffectType {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_type(value);
		AudioResult.check(result.status, "audio.busEffect.type");
		return result.out_type;
	}

	public function setEnabled(enabled:Bool):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_enabled(value, enabled),
			"audio.busEffect.setEnabled");
	}

	public function isEnabled():Bool {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_is_enabled(value);
		AudioResult.check(result.status, "audio.busEffect.isEnabled");
		return result.out_enabled;
	}

	/** Returns this effect's zero-based position in its bus chain. */
	public function position():Int {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_position(value);
		AudioResult.check(result.status, "audio.busEffect.position");
		return result.out_position;
	}

	/** Moves this effect to a zero-based position in its bus chain. */
	public function setPosition(position:Int):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_position(value, position),
			"audio.busEffect.setPosition");
	}

	public function setLowPass(cutoffFrequencyHz:Float, order:Int):Void {
		ensureLive();
		AudioResult.check(
			NativeKitAudio.nk_audio_bus_effect_set_low_pass(value, cutoffFrequencyHz, order),
			"audio.busEffect.setLowPass");
	}

	public function lowPass():FilterSettings {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_low_pass(value);
		AudioResult.check(result.status, "audio.busEffect.lowPass");
		return new FilterSettings(result.out_cutoff_frequency_hz, result.out_order);
	}

	public function setHighPass(cutoffFrequencyHz:Float, order:Int):Void {
		ensureLive();
		AudioResult.check(
			NativeKitAudio.nk_audio_bus_effect_set_high_pass(value, cutoffFrequencyHz, order),
			"audio.busEffect.setHighPass");
	}

	public function highPass():FilterSettings {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_high_pass(value);
		AudioResult.check(result.status, "audio.busEffect.highPass");
		return new FilterSettings(result.out_cutoff_frequency_hz, result.out_order);
	}

	public function setDelayWet(wet:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_delay_wet(value, wet),
			"audio.busEffect.setDelayWet");
	}

	public function delayWet():Float {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_delay_wet(value);
		AudioResult.check(result.status, "audio.busEffect.delayWet");
		return result.out_wet;
	}

	public function setDelayDry(dry:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_delay_dry(value, dry),
			"audio.busEffect.setDelayDry");
	}

	public function delayDry():Float {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_delay_dry(value);
		AudioResult.check(result.status, "audio.busEffect.delayDry");
		return result.out_dry;
	}

	public function setDelayDecay(decay:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_delay_decay(value, decay),
			"audio.busEffect.setDelayDecay");
	}

	public function delayDecay():Float {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_delay_decay(value);
		AudioResult.check(result.status, "audio.busEffect.delayDecay");
		return result.out_decay;
	}

	/** Sets delay tempo and duration in quarter-note beats as one validated update. */
	public function setDelayTempo(bpm:Float, beats:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_delay_tempo(value, bpm, beats),
			"audio.busEffect.setDelayTempo");
	}

	/** Sets a processor parameter; values are range-checked and changes smoothed. */
	public function setParameter(parameter:EffectParameter, value:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_set_parameter(this.value, parameter, value),
			"audio.busEffect.setParameter");
	}

	/** Returns the target value, rather than its intermediate smoothed value. */
	public function parameter(parameter:EffectParameter):Float {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_parameter(value, parameter);
		AudioResult.check(result.status, "audio.busEffect.parameter");
		return result.out_value;
	}

	/** Clears processor state/tails at its next processing block. */
	public function reset():Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_effect_reset(value), "audio.busEffect.reset");
	}

	public function latencyFrames():Int {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_latency(value);
		AudioResult.check(result.status, "audio.busEffect.latency");
		return result.out_frames;
	}

	/** Estimated frames to decay to -60 dB. */
	public function tailFrames():Int {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_effect_get_tail(value);
		AudioResult.check(result.status, "audio.busEffect.tail");
		return result.out_frames;
	}

	/** Removes this effect from its bus, or marks it released with its parent bus. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.Ok)
			throw new NativeKitError(status, "audio.busEffect.dispose", NativeKit.nk_last_error());
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw "Audio bus effect has been disposed";
	}
}
