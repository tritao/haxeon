package build;

import build.execution.ContentDigestCache;

/**
 * State a long-lived process (`haxeon run --watch`) keeps across its rebuilds, so each one pays only for what changed.
 * One-shot builds pass no session and keep fresh state.
 */
class BuildSession {
	/** File hashes that survive between builds; see `ContentDigestCache` for how a stale one is ruled out. */
	public final digests:ContentDigestCache;

	final workerVersions:Map<String, String> = [];

	/** How many worker versions were computed rather than remembered. */
	public var workerVersionsComputed(default, null) = 0;

	/**
	 * A live run's compile in the compiler worker, sent in the background. A run whose module is already built skips the
	 * compile, so its worker (perhaps a new one, after the old one exited) has not compiled the program; this lets it
	 * resume the module's history and type the program while the app starts, instead of on the first edit.
	 */
	public var liveWarmup:Null<Void->Int> = null;

	/** Whether this session's builds have sent the live compile to a compiler. */
	public var liveCompiled = false;

	/**
	 * The compiler workers this session's builds used (by state file), each with the time its next keepalive ping is due.
	 * While the session runs it pings them, so they do not idle out however long the user pauses.
	 */
	public final workerPings:Map<String, Float> = [];

	/** Work builds left for when the watch is idle, by key: a later build's replaces an earlier one's still waiting. */
	final idleWork:Map<String, Void -> Void> = [];

	final idleOrder:Array<String> = [];

	public function new(?digests:ContentDigestCache) {
		this.digests = digests == null ? new ContentDigestCache(true) : digests;
	}

	/**
	 * The compiler worker version for `identity`, computed once per session. A watched app keeps the worker whose patch
	 * history it was launched against, so a worker chosen at the first build stays chosen even if the compiler sources
	 * change underneath it; restart the watch to pick up a new compiler.
	 */
	/** Warms the live compile's worker when no build of this session has compiled; never waits for the compile. */
	public function warmLiveCompiler():Void {
		var warmup = liveWarmup;
		if (warmup != null && !liveCompiled) {
			liveCompiled = true;
			warmup();
		}
	}

	/** Leaves `work` for the next time the watch is idle, replacing what was left under `key`. */
	public function whenIdle(key:String, work:Void->Void):Void {
		if (!idleWork.exists(key))
			idleOrder.push(key);
		idleWork.set(key, work);
	}

	/**
		Runs the work builds left, in the order it was first left. The watch calls it when no save is pending and the sources are
		as the last build found them, and when it ends.
	**/
	public function runIdleWork():Void {
		var keys = idleOrder.splice(0, idleOrder.length);
		for (key in keys) {
			var work = idleWork.get(key);
			idleWork.remove(key);
			if (work != null)
				work();
		}
	}

	/** Keeps the workers this session uses resident; the watch loop calls it on every wake, and it pings only when one is due. */
	public function keepWorkersAlive():Void
		build.execution.CompilerClient.keepWorkersAlive(this);

	public function workerVersion(identity:String, compute:Void->String):String {
		var version = workerVersions.get(identity);
		if (version == null) {
			version = compute();
			workerVersions.set(identity, version);
			workerVersionsComputed++;
		}
		return version;
	}
}
