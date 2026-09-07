import profiler.HldiClient;
import profiler.ProfilerSession;

class ProfilerAllocationBenchmarkMain {
	static function main():Void {
		var args = Sys.args(), port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null) throw "Usage: profiler-allocation-benchmark.hl PORT";
		var session = new ProfilerSession(new HldiClient("127.0.0.1", port, 5.0));
		for (interval in [0, 1024, 64]) {
			session.reset();
			session.start(100, interval);
			for (_ in 0...15) { Sys.sleep(0.1); session.poll(); }
			var stats = session.snapshot().gcStats;
			if (stats.length < 2) throw "missing allocation benchmark counters";
			var first = stats[0], last = stats[stats.length - 1], seconds = last.timestamp - first.timestamp,
				allocations = Std.parseFloat(last.allocations) - Std.parseFloat(first.allocations);
			Sys.println('interval=$interval allocationsPerSecond=${Math.round(allocations / seconds)} sampledSites=${session.snapshot().allocationSamples.length}');
		}
		session.close();
	}
}
