package runtime;

/**
 * The record a strict live host leaves in `<module>.live.refused` when it refuses a revision: the module identity, the
 * revision the app keeps running and the refused one, as `<identity>:<running>:<refused>`. The compiler reads it before
 * its next build and takes the refused revisions back (`CompilerSession.takeBackRefusedRevisions`), so that build patches
 * the revision the app runs.
 */
class LiveRefusal {
	public static inline final SUFFIX:String = ".live.refused";

	public final identity:String;
	public final running:Int;
	public final refused:Int;

	public function new(identity:String, running:Int, refused:Int) {
		this.identity = identity;
		this.running = running;
		this.refused = refused;
	}

	/** Where the record of module `output` lives. */
	public static function path(output:String):String
		return output + SUFFIX;

	public function encode():String
		return identity + ":" + running + ":" + refused;

	/** The record `text` holds, or null when it is not one. */
	public static function parse(text:String):Null<LiveRefusal> {
		var fields = StringTools.trim(text).split(":");
		if (fields.length != 3)
			return null;
		var running = Std.parseInt(fields[1]), refused = Std.parseInt(fields[2]);
		if (running == null || refused == null)
			return null;
		var runningRevision:Int = running, refusedRevision:Int = refused;
		return new LiveRefusal(fields[0], runningRevision, refusedRevision);
	}
}
