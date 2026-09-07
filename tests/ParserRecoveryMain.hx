import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;

class ParserRecoveryMain {
	static function main():Void {
		var service = new LanguageService(), source =
			"class Box { public var value:Int; public function read():Int return value; } function main():Int { var box:Box = new Box(); box.";
		service.update("Main.hx", source);
		try
			service.analyze("Main")
		catch (_:CompileError) {}
		var names = [for (item in service.complete("Main.hx", source.length)) item.label];
		if (names.indexOf("value") < 0 || names.indexOf("read") < 0)
			throw "incomplete member access did not retain recovered receiver completion";

		var typeService = new LanguageService(), typeSource = "function main():Int { var unfinished:";
		typeService.update("Type.hx", typeSource);
		try
			typeService.analyze("Type")
		catch (_:CompileError) {}
		var locals = [for (item in typeService.complete("Type.hx", typeSource.length)) item.label];
		if (locals.indexOf("unfinished") < 0)
			throw "unfinished type annotation discarded its local declaration";
		Sys.println("PASS: incomplete member and type recovery support completion");
	}
}
