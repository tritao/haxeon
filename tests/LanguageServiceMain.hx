import compiler.service.LanguageService;
import compiler.Diagnostic.CompileError;

class LanguageServiceMain {
	static function main():Void {
		var service = new LanguageService();
		service.update("Main.hx",
			"typedef Count = Int; enum Kind { One; Two(Int); } interface Plugin { function activate():Void; } class Editor { public static var version:Int; public static function make():Int { return 1; } public var active:Int; public function open():Void { return; } } function main():Int { var editor = new Editor(); editor.open(); editor.active; var text:String = \"x\"; text.length; var kind:Kind = Kind.One; var values = new Array<Int>(0); values.push(1); values.pop(); Editor.make(); return 42; }");
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
		if (symbols[0].revision != 1 || symbols[0].stale)
			throw "language service did not tag the current semantic snapshot";
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
		var arrayPosition = source.indexOf("values.push") + "values.".length, arrayCompletion = service.complete("Main.hx", arrayPosition), hasPush = false,
			hasPop = false;
		for (item in arrayCompletion) {
			if (item.label == "push" && item.detail == "push(value):Int")
				hasPush = true;
			if (item.label == "pop" && item.detail == "pop():Element")
				hasPop = true;
		}
		if (!hasPush || !hasPop || service.hover("Main.hx", arrayPosition + 3) != "push(value):Int")
			throw "language service typed array completion failed";
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
		var localService = new LanguageService(),
			localSource = "function first(value:Int):Int { return value; } function second(value:Int):Int { return value; } function main():Int { return first(42); }";
		localService.update("Locals.hx", localSource);
		localService.compile("Locals");
		var localPosition = localSource.indexOf("return value") + "return ".length,
			localDefinition = localService.definition("Locals.hx", localPosition),
			localReferences = localService.references("Locals.hx", localPosition),
			localEdits = localService.rename("Locals.hx", localPosition, "item");
		var firstValue = localSource.indexOf("value");
		if (localDefinition == null
			|| localDefinition.span.start > firstValue
			|| localDefinition.span.end < firstValue
			|| localReferences.length != 2
			|| localEdits.length != 2)
			throw "language service local symbol scope was not preserved";
		var shadowService = new LanguageService(),
			shadowSource = "function main():Int { var value = 40; if (true) { var value = 2; value = value + 1; } return value + 2; }";
		shadowService.update("Shadow.hx", shadowSource);
		shadowService.compile("Shadow");
		var innerUse = shadowSource.indexOf("value = value + 1") + "value = ".length,
			outerUse = shadowSource.lastIndexOf("value + 2"),
			innerDefinition = shadowService.definition("Shadow.hx", innerUse),
			outerDefinition = shadowService.definition("Shadow.hx", outerUse),
			innerReferences = shadowService.references("Shadow.hx", innerUse),
			outerReferences = shadowService.references("Shadow.hx", outerUse);
		if (innerDefinition == null
			|| outerDefinition == null
			|| innerDefinition.span.start == outerDefinition.span.start
			|| innerReferences.length != 3
			|| outerReferences.length != 2)
			throw "language service confused shadowed local identities";
		var importService = new LanguageService();
		importService.update("editor/util/Math.hx", "package editor.util; function add(a:Int, b:Int):Int { return a + b; }");
		var importSource = "package editor; import editor.util.Math; function main():Int { return Math.add(20, 22); }";
		importService.update("editor/Main.hx", importSource);
		importService.compile("editor.Main");
		var importedPosition = importSource.indexOf("Math.add") + "Math.".length,
			importedDefinition = importService.definition("editor/Main.hx", importedPosition),
			importedReferences = importService.references("editor/Main.hx", importedPosition),
			importedEdits = importService.rename("editor/Main.hx", importedPosition, "sum");
		if (importService.compiler.modules.get("editor.Main").semanticModel.index.symbolIdAt(importedPosition) == null
			|| importedDefinition == null
			|| importedDefinition.path != "editor/util/Math.hx"
			|| importedReferences.length != 2
			|| importedEdits.length != 2)
			throw "language service imported symbol resolution failed";
		var hierarchyService = new LanguageService(),
			hierarchySource = "typedef ParentAlias = Parent; class Parent { public function value():Int { return 42; } } class Child extends Parent { } function main():Int { var child:Child = new Child(); return child.value(); }";
		hierarchyService.update("Hierarchy.hx", hierarchySource);
		hierarchyService.compile("Hierarchy");
		var inheritedUse = hierarchySource.lastIndexOf("value"),
			inheritedDefinition = hierarchyService.definition("Hierarchy.hx", inheritedUse),
			inheritedRename = hierarchyService.rename("Hierarchy.hx", inheritedUse, "score"),
			aliasUse = hierarchySource.indexOf("ParentAlias =") + "ParentAlias = ".length,
			aliasDefinition = hierarchyService.definition("Hierarchy.hx", aliasUse);
		if (hierarchyService.compiler.modules.get("Hierarchy").semanticModel.index.symbolIdAt(inheritedUse) == null
			|| inheritedDefinition == null
			|| inheritedDefinition.span.start > hierarchySource.indexOf("value")
			|| inheritedRename.length != 2
			|| aliasDefinition == null
			|| aliasDefinition.span.start > hierarchySource.indexOf("class Parent"))
			throw "language service did not resolve inheritance and alias navigation";
		var collisionService = new LanguageService(),
			collisionSource = "class Item { public function value():Int return 1; public function score():Int return value(); } function main():Int return new Item().value();";
		collisionService.update("Collision.hx", collisionSource);
		collisionService.compile("Collision");
		var collisionPosition = collisionSource.lastIndexOf("value") + 2;
		if (collisionService.rename("Collision.hx", collisionPosition, "score").length != 0
			|| collisionService.rename("Collision.hx", collisionPosition, "not-valid").length != 0)
			throw "language service allowed an unsafe rename";
		service.update("Main.hx", "function main(:Int { return 0; }");
		try {
			service.compile("Main");
			throw "invalid edit unexpectedly compiled";
		} catch (error:CompileError) {}
		var recoveredSymbols = service.documentSymbols("Main.hx"),
			recoveredCompletion = service.complete("Main.hx", 0);
		if (recoveredSymbols.length == 0 || recoveredCompletion.length == 0)
			throw "failed edit discarded the last good language-service snapshot";
		if (!recoveredSymbols[0].stale || recoveredSymbols[0].revision != 1 || !recoveredCompletion[0].stale)
			throw "failed edit did not identify stale semantic query results";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}
}
