import compiler.service.LanguageService;

class LanguageServiceMain {
	static function main():Void {
		var service = new LanguageService();
		service.update("Main.hx", "class Editor { public var active:Int; public function open():Void { return; } } function main():Int { return 42; }");
		service.compile("Main");
		var symbols = service.documentSymbols("Main.hx"),
			foundClass = false,
			foundMethod = false;
		for (symbol in symbols) {
			if (symbol.name == "Editor" && symbol.kind == "class")
				foundClass = true;
			if (symbol.name == "open" && symbol.kind == "method" && symbol.detail == "open():Void")
				foundMethod = true;
		}
		if (!foundClass || !foundMethod)
			throw "language service did not expose document symbols";
		var source = service.compiler.modules.get("Main").source.text,
			completion = service.complete("Main.hx", source.length),
			hasMain = false,
			hoverPosition = source.indexOf("main") + 4;
		for (item in completion)
			if (item.label == "main")
				hasMain = true;
		if (!hasMain || service.hover("Main.hx", hoverPosition) != "main():Int")
			throw "language service completion or hover failed";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}
}
