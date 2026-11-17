/**
 * The lint rules that need the compiler's analysis, which the command line (`tools.HaxeonCli`) does not link the compiler for:
 * `haxeon lint --only RULE FILE...` runs this tool with the rule and the files (`tools.TypedLint`).
 */
class LintMain {
	static function main():Void {
		var invokedFrom = Sys.getCwd();
		compiler.service.LanguageService.useHaxeonRoot();
		var arguments = Sys.args();
		Sys.exit(tools.TypedLint.run(arguments[0], arguments.slice(1), invokedFrom));
	}
}
