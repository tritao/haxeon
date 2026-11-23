import haxe.io.Bytes;
import haxeon.audio.Clip;
import haxeon.audio.Mixer;
import haxeon.audio.PcmFormat;
import haxeon.audio.Voice;
import haxeon.platform.PlatformError;

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

	public function new() {
		try {
			Mixer.startDevice();
			started = true;
			voices.set(Pickup, makeVoice([740, 1040], 0.035));
			voices.set(Caught, makeVoice([310, 185, 110], 0.095));
			voices.set(Clear, makeVoice([520, 660, 790, 1040], 0.085));
			available = true;
		} catch (error:PlatformError) {
			reportUnavailable(error);
		}
	}

	public function play(effect:SoundEffect):Void {
		if (!available || muted)
			return;
		try {
			var voice = voices.get(effect);
			if (voice != null) {
				voice.rewind();
				voice.start();
			}
		} catch (error:PlatformError) {
			reportUnavailable(error);
		}
	}

	public function soundEnabled():Bool return available && !muted;

	public function toggleMute():Void {
		muted = !muted;
		if (available && muted) {
			try {
				for (voice in voices)
					voice.stop();
			} catch (error:PlatformError) {
				reportUnavailable(error);
			}
		}
	}

	public function dispose():Void {
		for (voice in voices)
			voice.dispose();
		if (started)
			Mixer.stopDevice();
	}

	function reportUnavailable(error:PlatformError):Void {
		available = false;
		Sys.stderr().writeString("Circuit Run audio unavailable: " + Std.string(error) + "\n");
	}

	static function makeVoice(notes:Array<Int>, noteSeconds:Float):Voice {
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

		scoped var clip = Clip.fromPcm(pcm, sampleRate, 1, PcmFormat.Signed16LE);
		return clip.createVoice();
	}
}
