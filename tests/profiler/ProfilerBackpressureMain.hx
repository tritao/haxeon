import profiler.HldiClient;
import profiler.ProfilerSession;

class ProfilerBackpressureMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Void {
		var args = Sys.args(),
			port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null)
			throw "Usage: profiler-backpressure-test.hl PORT";
		var session = new ProfilerSession(new HldiClient("127.0.0.1", port, 15.0));
		try {
			session.start(250);
			// Deliberately stop consuming long enough to put pressure on the runtime ring.
			Sys.sleep(8.0);
			for (_ in 0...24) {
				session.poll(64 * 1024);
				Sys.sleep(0.05);
			}
			var snapshot = session.snapshot();
			require(snapshot.bufferCapacity > 0, "missing buffer capacity");
			require(snapshot.bufferUsed >= 0 && snapshot.bufferUsed <= snapshot.bufferCapacity, "profiler buffer was not bounded");
			require(snapshot.requestedSampleRate == 250, "requested sampling rate changed");
			require(snapshot.effectiveSampleRate > 0 && snapshot.effectiveSampleRate < snapshot.requestedSampleRate,
				"adaptive sampling did not reduce the effective rate");
			var sawRevision2 = false;
			for (revision in snapshot.metadataRevisions)
				if (revision == 2)
					sawRevision2 = true;
			require(sawRevision2, "metadata did not follow hot reload under pressure");
			require(snapshot.unresolvedFrames == 0, "slow transport produced unresolved frames");
			Sys.println('PASS: bounded profiler pressure=${snapshot.bufferUtilization} rate=${snapshot.effectiveSampleRate}/${snapshot.requestedSampleRate} dropped=${snapshot.dropped}');
		} catch (error:Dynamic) {
			session.close();
			throw error;
		}
		session.close();
	}
}
