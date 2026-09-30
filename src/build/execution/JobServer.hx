package build.execution;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.Process;

/**
 * A GNU make jobserver in the FIFO style, so Ninja 1.13+ (and make 4.4+) can share one token pool with
 * Haxeon's own actions. Each running job holds one token; a client that runs several jobs, such as a
 * Ninja build, reads more tokens from the FIFO and returns them as its jobs finish.
 *
 * A helper shell keeps the FIFO open read-write so tokens survive between readers and it vanishes with
 * the pool if Haxeon dies. Tokens are moved by short `dd` and `printf` processes rather than by reading
 * the FIFO in-process, because a HashLink thread blocked in a raw read cannot be paused for GC.
 */
class JobServer {
	public final path:String;
	public final tokens:Int;

	/** Value for MAKEFLAGS in the environment of a jobserver client. */
	public final makeFlags:String;

	var holder:Null<Process>;

	function new(path:String, tokens:Int, holder:Process) {
		this.path = path;
		this.tokens = tokens;
		this.makeFlags = ' -j$tokens --jobserver-auth=fifo:$path';
		this.holder = holder;
	}

	/** Returns null where FIFOs are unavailable or the pool cannot be created. */
	public static function start(directory:String, tokens:Int):Null<JobServer> {
		if (Sys.systemName() == "Windows" || tokens < 1)
			return null;
		var fifo = Path.join([directory, "jobserver-" + Std.string(Std.random(1000000000)) + ".fifo"]);
		try {
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
			if (Sys.command("mkfifo", ["-m", "600", fifo]) != 0)
				return null;
			// `$0` is the FIFO and `$1` the token bytes. Exit once Haxeon is gone so an aborted build leaves no pool.
			var script = 'exec 9<>"$$0" || exit 1; printf %s "$$1" >&9; echo ready; while kill -0 $$PPID 2>/dev/null; do sleep 1; done',
				process = new Process("sh", ["-c", script, fifo, StringTools.lpad("", "+", tokens)]);
			if (process.stdout.readLine() != "ready") {
				process.kill();
				process.close();
				return null;
			}
			return new JobServer(fifo, tokens, process);
		} catch (_:Dynamic) {
			try
				FileSystem.deleteFile(fifo)
			catch (_:Dynamic) {}
			return null;
		}
	}

	/** Blocks until a token is available. The caller must `release` it. */
	public function acquire():Bool // One byte at a time: a larger read would swallow tokens that belong to other jobs.
		return ProcessRunner.run("sh", ["-c", 'dd if="$$0" of=/dev/null bs=1 count=1 2>/dev/null', path], "", new Map(), false) == 0;

	public function release():Void
		ProcessRunner.run("sh", ["-c", 'printf + > "$$0"', path], "", new Map(), false);

	public function stop():Void {
		if (holder != null) {
			holder.kill();
			holder.close();
			holder = null;
		}
		try
			FileSystem.deleteFile(path)
		catch (_:Dynamic) {}
	}
}
