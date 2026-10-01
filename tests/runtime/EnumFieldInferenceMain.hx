import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.Runtime;

/**
 * A field initialized with an enum constructor or an enum abstract value takes that type without an annotation,
 * whether the constructor carries arguments or not and whether the field is static or an instance field.
 */
class EnumFieldInferenceMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("motion/MoveKind.hx", "package motion; enum MoveKind { Rapid; Feed(rate:Int); }");
		compiler.update("motion/Mode.hx", "package motion; enum abstract Mode(Int) from Int to Int { var Slow = 3; var Fast = 7; }");
		compiler.update("motion/Generic.hx", "package motion; enum Choice<T> { Some(value:T); None; }");
		compiler.update("motion/Planner.hx",
			"package motion; class Planner { public final kind = MoveKind.Rapid; public final feed = MoveKind.Feed(40); "
			+ "public static final fallback = MoveKind.Feed(2); public static final idle = motion.MoveKind.Rapid; public static final mode = Mode.Fast; "
			+ "public var gear = Mode.Slow; public function new() {} "
			+ "public function describe():Int return switch kind { case Rapid: 100; case Feed(rate): rate; } }");
		compiler.update("Main.hx",
			"import motion.MoveKind; import motion.Planner; class Holder { public static final mode = MoveKind.Feed(5); } function main():Int { var planner = new Planner(); "
			+ "var feed:Int = switch planner.feed { case Rapid: 0; case Feed(rate): rate; }; "
			+ "var fallback:Int = switch Planner.fallback { case Rapid: 0; case Feed(rate): rate; }; "
			+ "var idle:Int = switch Planner.idle { case Rapid: 1000; case Feed(rate): rate; }; "
			+ "var chosen:Int = switch Holder.mode { case Rapid: 0; case Feed(rate): rate; }; "
			+ "var mode:Int = Planner.mode; var gear:Int = planner.gear; "
			+ "return planner.describe() + feed + fallback + idle + chosen + mode * 10000 + gear * 100000; }");
		var result = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
		var value = Runtime.callInt(live, result.functionIds.get("main"));
		Runtime.dispose(live);
		if (value != 100 + 40 + 2 + 1000 + 5 + 70000 + 300000)
			throw 'Enum constructor fields were typed or initialized wrongly: $value';
		Sys.println("PASS: fields initialized with enum constructors or enum abstract values infer their type");
	}
}
