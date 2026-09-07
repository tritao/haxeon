import editor.profiler.ProfilerService;
import haxe.Json;
import sys.thread.Mutex;

class ProfilerProtocolBenchmarkMain {
	static function main():Void {
		var args = Sys.args(), port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null) throw "Usage: profiler-protocol-benchmark.hl PORT";
		var service = new ProfilerService(), mutex = new Mutex(), sizes:Array<Int> = [];
		service.setEmitter(message -> {
			mutex.acquire();
			sizes.push(Json.stringify(message).length);
			mutex.release();
		});
		service.execute("haxeon.profiler.connect", [{port: port, timeoutSeconds: 3.0}]);
		for (rate in [100, 250, 1000]) {
			mutex.acquire(); sizes.resize(0); mutex.release();
			service.execute("haxeon.profiler.reset", []);
			service.execute("haxeon.profiler.start", [{sampleRate: rate, pollIntervalMs: 100}]);
			Sys.sleep(1.5);
			service.execute("haxeon.profiler.pause", []);
			mutex.acquire();
			var total = 0, peak = 0;
			for (size in sizes) { total += size; if (size > peak) peak = size; }
			var count = sizes.length;
			mutex.release();
			if (count < 5) throw 'too few profiler messages at $rate Hz';
			Sys.println('rate=$rate messages=$count averageBytes=${Math.round(total / count)} peakBytes=$peak bytesPerSecond=${Math.round(total / 1.5)}');
		}
		service.close();
	}
}
