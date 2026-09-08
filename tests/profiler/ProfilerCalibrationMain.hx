import profiler.HldiClient;
import profiler.ProfilerSession;

class ProfilerCalibrationMain {
	static function main():Void {
		var args = Sys.args(),
			port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null)
			throw "Usage: profiler-calibration-test.hl PORT";
		var session = new ProfilerSession(new HldiClient("127.0.0.1", port, 5.0));
		for (rate in [100, 250, 1000]) {
			session.start(rate);
			var before = session.sampleRecords;
			for (_ in 0...10) {
				Sys.sleep(0.1);
				session.poll();
			}
			session.pause();
			var snapshot = session.snapshot();
			if (snapshot.sampleRecords <= before || snapshot.generatedBytes <= 0 || snapshot.overheadMicrosPerSample <= 0)
				throw 'missing calibration telemetry at $rate Hz';
			Sys.println('rate=$rate effective=${snapshot.effectiveSampleRate} samples=${snapshot.sampleRecords - before} overhead_us=${snapshot.overheadMicrosPerSample} bytes=${snapshot.generatedBytes}');
		}
		session.close();
		Sys.println("PASS: profiler overhead calibrated at 100, 250, and 1000 Hz");
	}
}
