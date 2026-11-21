package compiler.tools;

/**
 * How much a build says (`haxeon build -v LEVEL`, the compiler's `--verbosity=LEVEL`). Each level prints what the ones before
 * it print, and more: `quiet` only diagnostics, `minimal` a line before and after the build, `normal` each action and the
 * compiler's progress, `detailed` the worker's costs, `diagnostic` every phase, pass and allocation report.
 */
enum abstract Verbosity(Int) {
	var Quiet = 0;
	var Minimal = 1;
	var Normal = 2;
	var Detailed = 3;
	var Diagnostic = 4;

	public static final NAMES = ["quiet", "minimal", "normal", "detailed", "diagnostic"];

	/** dotnet's short names for the same levels. */
	static final SHORT = ["q", "m", "n", "d", "diag"];

	/** The level `name` (or its dotnet short name) names, or null. */
	public static function parse(name:String):Null<Verbosity> {
		for (index in 0...NAMES.length)
			if (name == NAMES[index] || name == SHORT[index])
				return cast index;
		return null;
	}

	public inline function atLeast(level:Verbosity):Bool
		return this >= (cast level:Int);

	public function name():String
		return NAMES[this];
}
