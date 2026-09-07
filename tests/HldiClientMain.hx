import profiler.HldiClient;
import profiler.ProfilerSession;

class HldiClientMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length < 1 || args.length > 2)
			throw "Usage: hldi-client-test.hl PORT [TOKEN]";
		var port = Std.parseInt(args[0]);
		if (port == null)
			throw "Invalid port";

		var client = new HldiClient("127.0.0.1", port, 3.0, args.length == 2 ? args[1] : null);
		require(client.hello.version == 1, "unexpected protocol version");
		require(client.hello.capabilities & (HldiClient.CAP_PROFILER | HldiClient.CAP_SYMBOLS) == 3, "missing profiler capabilities");
		var session = new ProfilerSession(client);
		try {
			session.start(500);
			require(session.bufferCapacity > 0, "expected profiler buffer capacity telemetry");
			require(session.requestedSampleRate == 500 && session.effectiveSampleRate > 0, "expected profiler rate telemetry");
			require(session.metadata != null && session.metadata.schema == 4, "expected schema 4 metadata");
			require(session.metadata.symbols.length > 0, "expected JIT symbols");
			var sourceMappings = 0;
			for (symbol in session.metadata.symbols)
				for (location in symbol.lines) {
					require(location.endOffset > location.offset, "expected a non-empty opcode range");
					sourceMappings++;
				}
			require(sourceMappings > 0, "expected source mappings");

			for (_ in 0...8) {
				Sys.sleep(0.05);
				session.poll();
			}
			session.pause();
			var snapshot = session.snapshot();
			require(snapshot.samples > 0, "expected profiler samples");
			require(snapshot.functions.length > 0, "expected function aggregates");
			require(snapshot.stacks.length > 0, "expected stack aggregates");
			require(snapshot.pendingBytes == 0, "expected complete profiler records");
			Sys.println('HLDI client OK: pid=${client.hello.processId} symbols=${session.metadata.symbols.length} lines=$sourceMappings samples=${snapshot.samples} unresolved=${snapshot.unresolvedFrames}');
		} catch (error:Dynamic) {
			session.close();
			throw error;
		}
		session.close();
	}
}
