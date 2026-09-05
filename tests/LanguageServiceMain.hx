import compiler.service.LanguageService;

class LanguageServiceMain {
	static function main():Void {
		var service = new LanguageService();
		service.update("Main.hx",
			"typedef Count = Int; enum Kind { One; } interface Plugin { function activate():Void; } class Editor { public var active:Int; public function open():Void { return; } } function main():Int { var editor = new Editor(); editor.open(); return 42; }");
		service.compile("Main");
		var symbols = service.documentSymbols("Main.hx"),
			foundClass = false,
			foundMethod = false,
			foundAlias = false,
			foundInterface = false,
			foundEnum = false;
		for (symbol in symbols) {
			if (symbol.name == "Editor" && symbol.kind == "class")
				foundClass = true;
			if (symbol.name == "open" && symbol.kind == "method" && symbol.detail == "open():Void")
				foundMethod = true;
			if (symbol.name == "Count" && symbol.kind == "type")
				foundAlias = true;
			if (symbol.name == "Plugin" && symbol.kind == "interface")
				foundInterface = true;
			if (symbol.name == "Kind" && symbol.kind == "enum")
				foundEnum = true;
		}
		if (!foundClass || !foundMethod || !foundAlias || !foundInterface || !foundEnum)
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
		var methodPosition = source.lastIndexOf("open") + 2,
			definition = service.definition("Main.hx", methodPosition);
		if (definition == null
			|| definition.path != "Main.hx"
			|| definition.span.start > source.indexOf("open")
			|| definition.span.end < source.indexOf("open"))
			throw "language service definition query failed";
		var references = service.references("Main.hx", methodPosition);
		if (references.length != 2)
			throw 'language service references expected declaration and call, got ${references.length}';
		var edits = service.rename("Main.hx", methodPosition, "show");
		if (edits.length != 2 || edits[0].replacement != "show" || edits[1].replacement != "show")
			throw "language service rename query failed";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}
}
