import profiler.HldiClient;
import profiler.ProfilerSession;

class ProfilerReconnectMain {
	static function main():Void {
		var args = Sys.args(), port = args.length == 2 ? Std.parseInt(args[0]) : null;
		if (port == null) throw "Usage: profiler-reconnect-test.hl PORT TOKEN";
		var first = connect(port, args[1]), sawDisconnect = false;
		while (!sawDisconnect) {
			try {
				Sys.sleep(0.05);
				first.poll();
			} catch (_:Dynamic) sawDisconnect = true;
		}
		first.close();
		var delay = 0.1, deadline = Sys.time() + 10.0, second:Null<ProfilerSession> = null;
		while (second == null && Sys.time() < deadline) {
			try second = connect(port, args[1]) catch (_:Dynamic) {
				Sys.sleep(delay);
				delay = Math.min(1.0, delay * 2);
			}
		}
		if (second == null) throw "profiler did not reconnect after runtime restart";
		Sys.sleep(0.1);
		second.poll();
		if (second.snapshot().samples == 0) throw "reconnected profiler produced no samples";
		second.close();
		Sys.println("PASS: profiler reconnects after runtime restart with bounded backoff");
	}

	static function connect(port:Int, token:String):ProfilerSession {
		var session = new ProfilerSession(new HldiClient("127.0.0.1", port, 1.0, token));
		session.start(100);
		return session;
	}
}
