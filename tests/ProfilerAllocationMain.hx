import profiler.HldiClient;
import profiler.ProfilerSession;

class ProfilerAllocationMain {
	static function main():Void {
		var args = Sys.args(), port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null) throw "Usage: profiler-allocation-test.hl PORT";
		var session = new ProfilerSession(new HldiClient("127.0.0.1", port, 5.0));
		session.start(100);
		for (_ in 0...24) { Sys.sleep(0.1); session.poll(); }
		var snapshot = session.snapshot(), values = snapshot.gcStats;
		if (values.length < 2) throw "missing GC counter timeline";
		var first = values[0], last = values[values.length - 1];
		if (Std.parseFloat(last.allocated) <= Std.parseFloat(first.allocated) || Std.parseFloat(last.allocations) <= Std.parseFloat(first.allocations))
			throw "allocation counters did not increase";
		if (session.nativeSymbolCount() == 0) throw "missing native symbol metadata";
		var nativeLocation = false;
		for (stack in snapshot.stacks)
			for (frame in stack.frameDetails)
				if (frame.nativeModule != null && frame.nativeOffset != null) nativeLocation = true;
		if (!nativeLocation) throw "missing native module/offset attribution";
		session.close();
		Sys.println('PASS: allocation and GC counters increased; nativeSymbols=${session.nativeSymbolCount()}');
	}
}
