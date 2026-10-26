import build.BuildSession;
import sys.FileSystem;
import sys.thread.Thread;

/**
 * A watch session keeps its compiler worker however long it pauses: its keepalive pings count as activity. Once the
 * session stops pinging (it ended or died), the worker still exits within its idle timeout, as an unused one does.
 */
@:access(compiler.tools.CompilerServer)
class CompilerKeepAliveMain {
	static final IDLE_SECONDS = 1;

	static function main():Void {
		Sys.putEnv("HAXEON_COMPILER_IDLE_SECONDS", Std.string(IDLE_SECONDS));
		var root = FileSystem.fullPath(".") + "/out/compiler-keepalive-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);

		// Without a session the worker idles out.
		var unused = root + "/unused.json";
		start(unused);
		expect(exitsWithin(unused, IDLE_SECONDS + 2), "a worker nobody pings must exit after its idle timeout");

		// A session pausing for three idle timeouts keeps its worker.
		var kept = root + "/kept.json", session = new BuildSession();
		start(kept);
		session.workerPings.set(kept, 0);
		var pauseEnd = Sys.time() + IDLE_SECONDS * 3;
		while (Sys.time() < pauseEnd) {
			session.keepWorkersAlive();
			Sys.sleep(0.05);
		}
		expect(FileSystem.exists(kept), "a worker the session pings must not idle out during a long pause");
		expect(session.workerPings.exists(kept), "the session must still know its worker");

		// The session ends: no more pings, and the worker exits within a bounded time.
		expect(exitsWithin(kept, IDLE_SECONDS + 2), "a worker must exit after its session stops pinging");

		// A gone worker is forgotten, so the session does not keep trying it.
		session.keepWorkersAlive();
		expect(!session.workerPings.exists(kept), "a session must forget a worker that is gone");
		Sys.println("compiler keepalive passed");
	}

	static function start(statePath:String):Void {
		Thread.create(() -> compiler.tools.CompilerServer.serve(statePath));
		var deadline = Sys.time() + 30;
		while (!FileSystem.exists(statePath) && Sys.time() < deadline)
			Sys.sleep(0.01);
		expect(FileSystem.exists(statePath), "the worker must publish its state file");
	}

	/** The worker removes its state file as it exits. */
	static function exitsWithin(statePath:String, seconds:Float):Bool {
		var deadline = Sys.time() + seconds;
		while (FileSystem.exists(statePath) && Sys.time() < deadline)
			Sys.sleep(0.05);
		return !FileSystem.exists(statePath);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition) {
			Sys.stderr().writeString(message + "\n");
			Sys.exit(1);
		}
	}
}
