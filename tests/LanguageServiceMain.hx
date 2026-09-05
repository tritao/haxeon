import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;

class LanguageServiceMain {
	static function main():Void {
		var service = new LanguageService();
		service.update("Main.hx",
			"typedef Count = Int; enum Kind { One; Two(Int); } interface Plugin { function activate():Void; } class Editor { public static var version:Int; public static function make():Int { return 1; } public var active:Int; public function open():Void { return; } } function main():Int { var editor = new Editor(); editor.open(); editor.active; var text:String = \"x\"; text.length; var kind:Kind = Kind.One; Editor.make(); return 42; }");
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
		var kindStart = source.indexOf("Kind.One"), kindCompletionPosition = kindStart + "Kind.".length, kindPosition = kindStart + "Kind.One".length,
			kindCompletion = service.complete("Main.hx", kindCompletionPosition), hasTwo = false;
		for (item in kindCompletion)
			if (item.label == "Two" && item.detail == "Kind.Two(Int)")
				hasTwo = true;
		if (!hasTwo || service.hover("Main.hx", kindPosition) != "Kind.One()")
			throw "language service member completion or enum hover failed";
		var classPosition = source.indexOf("Editor.make") + "Editor.".length,
			classCompletion = service.complete("Main.hx", classPosition),
			hasMake = false;
		for (item in classCompletion)
			if (item.label == "make" && item.detail == "make():Int")
				hasMake = true;
		if (!hasMake)
			throw "language service static member completion failed";
		var instancePosition = source.indexOf("editor.active") + "editor.".length,
			instanceCompletion = service.complete("Main.hx", instancePosition),
			hasActive = false;
		for (item in instanceCompletion)
			if (item.label == "active" && item.detail == "active:Int")
				hasActive = true;
		var instanceHoverPosition = source.indexOf("editor.active") + "editor.active".length;
		if (!hasActive || service.hover("Main.hx", instanceHoverPosition) != "active:Int")
			throw "language service typed instance completion failed";
		var stringPosition = source.indexOf("text.length") + "text.".length,
			stringCompletion = service.complete("Main.hx", stringPosition),
			hasLength = false;
		for (item in stringCompletion)
			if (item.label == "length" && item.detail == "length:Int")
				hasLength = true;
		if (!hasLength || service.hover("Main.hx", stringPosition + 3) != "length:Int")
			throw "language service typed string completion failed";
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
		service.update("Main.hx", "function main(:Int { return 0; }");
		try {
			service.compile("Main");
			throw "invalid edit unexpectedly compiled";
		} catch (error:CompileError) {}
		if (service.documentSymbols("Main.hx").length == 0 || service.complete("Main.hx", 0).length == 0)
			throw "failed edit discarded the last good language-service snapshot";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}
}
