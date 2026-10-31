package haxeon.ui.debug;

/** Opt-in render diagnostics; counters and formatting are untouched on ordinary frames. */
class RenderCost {
	public static final enabled:Bool = Sys.getEnv("HAXEON_UI_RENDER_COST") == "1";
	public static var callbacks = 0.0;
	public static var encode = 0.0;
	public static var renderable = 0.0;
	public static var nativeCall = 0.0;

	public static inline function time():Float return enabled ? Sys.time() : 0.0;

	public static function begin():Void {
		if (!enabled) return;
		callbacks = encode = renderable = nativeCall = 0.0;
	}

	public static function submit(started:Float, viewStarted:Float, nativeStarted:Float,
			nativeEnded:Float, ended:Float, nodes:Int):Void {
		if (!enabled) return;
		Sys.stderr().writeString('render-cost submit started=$started nodes=$nodes build=${nativeStarted - viewStarted}'
			+ ' layout=${nativeEnded - nativeStarted} other=${viewStarted - started + ended - nativeEnded}\n');
	}

	public static function render(started:Float, nativeStarted:Float, ended:Float, nodes:Int):Void {
		if (!enabled) return;
		Sys.stderr().writeString('render-cost haxe started=$started nodes=$nodes total=${ended - started}'
			+ ' walk=${nativeStarted - started} callbacks=$callbacks encode=$encode renderable=$renderable native=$nativeCall\n');
	}
}
