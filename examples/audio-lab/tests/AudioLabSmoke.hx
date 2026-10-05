import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import audiolab.AudioLabEngine;
import audiolab.AudioLabPreset;

/** Native DSP smoke test for the Audio Lab's preset and event host. */
class AudioLabSmoke {
	public static function main():Void {
		var init = new InitOptions();
		init.set_api_version(NativeKit.nk_api_version());
		if (NativeKit.nk_init(init) != Result.Ok)
			throw "Audio Lab smoke test could not initialize NativeKit";

		var lab = new AudioLabEngine();
		lab.noteOn(60, 0.8);
		lab.setFilterCutoff(620.0);
		lab.advance(0.03);
		if (lab.frame <= 0 || lab.eventCount <= 0 || lab.peak <= 0.0 || lab.rms <= 0.0)
			throw "Audio Lab smoke test did not render a live voice";

		for (id in AudioLabPreset.ids()) {
			lab.selectPreset(id);
			lab.noteOn(64, 0.7);
			lab.advance(0.02);
			if (lab.preset != id || lab.peak <= 0.0)
				throw "Audio Lab preset did not produce signal: " + AudioLabPreset.label(id);
		}

		lab.toggleTracker();
		lab.advance(0.25);
		if (!lab.trackerPlaying || lab.trackerStep == 0)
			throw "Audio Lab tracker clock did not advance";
		lab.dispose();
		NativeKit.nk_shutdown();
	}
}
