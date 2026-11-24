import model.Counter;
import model.Report;

/** A live host app (`haxeon run --watch` patches it): the host calls `start`, then `tick` until it returns 0. */
class Main {
	static var counter = new Counter();
	static var ticks = 0;

	public static function start(arguments:String):Void {}

	public static function tick():Int {
		Sys.sleep(0.005);
		counter.step();
		if (++ticks % 200 == 0)
			Sys.println(Report.describe(counter));
		return 1;
	}

	public static function saveState():String
		return Std.string(counter.total);

	public static function restoreState(state:String):Void
		counter.total = Std.parseInt(state) ?? 0;

	public static function close():Int
		return 0;

	public static function main():Void {}
}
