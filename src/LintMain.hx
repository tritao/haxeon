/**
 * The lint rules that need the compiler's analysis, which the command line (`tools.HaxeonCli`) does not link the compiler for:
 * `haxeon lint --only RULE FILE...` runs this tool with the rule and the files (`tools.TypedLint`).
 */
class LintMain {
	static function main():Void
		Sys.exit(run(Sys.args()));

	/** `haxeon lint` names its SDK's standard library first: `--stdlib=PATH RULE FILE...`. */
	public static function run(arguments:Array<String>):Int {
		var stdlib = "stdlib";
		arguments = arguments.copy();
		if (arguments.length > 0 && StringTools.startsWith(arguments[0], "--stdlib="))
			stdlib = arguments.shift().substr("--stdlib=".length);
		return tools.TypedLint.run(arguments[0], arguments.slice(1), Sys.getCwd(), stdlib);
	}
}
