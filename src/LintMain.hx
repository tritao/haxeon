/**
 * The lint rules that need the compiler's analysis, which the command line (`tools.HaxeonCli`) does not link the compiler for:
 * `haxeon lint --only RULE FILE...` runs this tool with the rule and the files (`tools.TypedLint`).
 */
class LintMain {
	static function main():Void {
		// `haxeon lint` names its SDK's standard library first: `--stdlib=PATH RULE FILE...`.
		var arguments = Sys.args(), stdlib = "stdlib";
		if (arguments.length > 0 && StringTools.startsWith(arguments[0], "--stdlib="))
			stdlib = arguments.shift().substr("--stdlib=".length);
		Sys.exit(tools.TypedLint.run(arguments[0], arguments.slice(1), Sys.getCwd(), stdlib));
	}
}
