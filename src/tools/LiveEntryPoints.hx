package tools;

/** The static functions of an app's entry class the live host (`LiveHost`) calls, by name. */
class LiveEntryPoints {
	/**
	 * The ones every app it hosts declares: `start(arguments:String):Void` once, `tick():Int` until it returns 0, `close():Int`
	 * at the end, and `saveState():String` and `restoreState(state:String):Void` around a reload. `haxeon run --watch` runs an
	 * app whose entry class declares them all in the host (`LiveHostBuild.missingEntryPoints`), and relaunches any other.
	 */
	public static final REQUIRED:Array<String> = [START, TICK, SAVE_STATE, RESTORE_STATE, CLOSE];

	public static inline final START:String = "start";
	public static inline final TICK:String = "tick";
	public static inline final SAVE_STATE:String = "saveState";
	public static inline final RESTORE_STATE:String = "restoreState";
	public static inline final CLOSE:String = "close";

	/**
	 * Optional ones the host calls around a patch (`Runtime.patchSetRebuilding`): `liveRelease()`, only before a patch that drops
	 * functions (one with guards), lets go of what the app rebuilds from its code, its UI and the callbacks it holds;
	 * `liveRebuild()`, after every patch, builds it again, from the patched code when the patch applied.
	 */
	public static inline final RELEASE:String = "liveRelease";

	public static inline final REBUILD:String = "liveRebuild";

	/**
	 * Every entry point the host may call. A live build roots each the entry class declares, as a one-shot build roots `main`,
	 * since nothing in the program calls them (docs/design/LIVE_PRUNING.md).
	 */
	public static final ALL:Array<String> = REQUIRED.concat([RELEASE, REBUILD]);
}
