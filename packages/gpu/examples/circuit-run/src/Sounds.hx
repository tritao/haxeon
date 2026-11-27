import haxe.io.Bytes;
import haxeon.audio.Clip;
import haxeon.audio.Mixer;
import haxeon.audio.PcmFormat;
import haxeon.audio.Voice;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitException;

enum SoundEffect {
	Pickup;
	Caught;
	Clear;
}

class Sounds implements Disposable {
	static inline var sampleRate = 48000;
	final voices:Map<SoundEffect, Voice> = new Map();
	var started = false;
	var muted = false;
	var available = false;
	var pending:Null<SoundEffect>;

	public function new() {
		switch start() {
			case Ok():
				available = true;
			case Err(error):
				reportUnavailable(error.describe());
		}
	}

	/** Starts the device and makes the game's voices, or answers why there is no sound. */
	function start():Result<Void, NativeKitError> {
		try Mixer.startDevice();
		started = true;
		voices.set(Pickup, try makeVoice([740, 1040], 0.035));
		voices.set(Caught, try makeVoice([310, 185, 110], 0.095));
		voices.set(Clear, try makeVoice([520, 660, 790, 1040], 0.085));
		return Ok();
	}

	/** Coalesces cues from simulation ticks until the native frame callback returns. */
	public function enqueue(effect:SoundEffect):Void
		pending = effect;

	public function clear():Void
		pending = null;

	public function flush():Void {
		var effect = pending;
		clear();
		if (effect != null)
			play(effect);
	}

	function play(effect:SoundEffect):Void {
		if (!available || muted)
			return;
		try {
			var voice = voices.get(effect);
			if (voice != null) {
				voice.rewind();
				voice.start();
			}
		} catch (error:NativeKitException) {
			reportUnavailable(error.error.describe());
		}
	}

	public function soundEnabled():Bool return available && !muted;

	public function toggleMute():Void {
		muted = !muted;
		if (available && muted) {
			try {
				for (voice in voices)
					voice.stop();
			} catch (error:NativeKitException) {
				reportUnavailable(error.error.describe());
			}
		}
	}

	public function dispose():Void {
		for (voice in voices)
			voice.dispose();
		if (started)
			Mixer.stopDevice();
	}

	function reportUnavailable(reason:String):Void {
		available = false;
		Sys.stderr().writeString("Circuit Run audio unavailable: " + reason + "\n");
	}

	static function makeVoice(notes:Array<Int>, noteSeconds:Float):Result<Voice, NativeKitError> {
		var noteFrames = Std.int(sampleRate * noteSeconds);
		var pcm = Bytes.alloc(2 * noteFrames * notes.length);
		var offset = 0;
		for (frequency in notes) {
			for (frame in 0...noteFrames) {
				var progress = frame / (noteFrames - 1);
				var envelope = Math.min(1.0, progress * 20.0) * (1.0 - progress);
				var phase = 2.0 * Math.PI * frequency * frame / sampleRate;
				var sample = Std.int(3700.0 * envelope * Math.sin(phase));
				pcm.setUInt16(offset, sample);
				offset += 2;
			}
		}

		scoped var clip = try Clip.fromPcm(pcm, sampleRate, 1, PcmFormat.Signed16LE);
		return Ok(clip.createVoice());
	}
}
