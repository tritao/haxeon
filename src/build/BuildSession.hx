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
