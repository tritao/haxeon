/**
 * The lint rules that need types, which the command line (`tools.HaxeonCli`) does not link the compiler for: `haxeon lint --only
 * unbound-local FILE...` runs this tool with the files (`tools.UnboundLocalLint`).
 */
class LintMain {
	static function main():Void {
		var invokedFrom = Sys.getCwd();
		compiler.service.LanguageService.useHaxeonRoot();
		Sys.exit(tools.UnboundLocalLint.run(Sys.args(), invokedFrom));
	}
}
