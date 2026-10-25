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

	public function new(?digests:ContentDigestCache) {
		this.digests = digests == null ? new ContentDigestCache(true) : digests;
	}

	/**
	 * The compiler worker version for `identity`, computed once per session. A watched app keeps the worker whose patch
	 * history it was launched against, so a worker chosen at the first build stays chosen even if the compiler sources
	 * change underneath it; restart the watch to pick up a new compiler.
	 */
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
