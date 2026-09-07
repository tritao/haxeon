import compiler.service.LanguageService;
import compiler.service.CancellationToken;
import compiler.service.SourceFormatter;
import compiler.Diagnostic.CompileError;

class LanguageServiceMain {
	static function main():Void {
		var formatSource = "function main():Int {\nvar text = \"{ literal }\"; // }\n/* keep { } */\nif (true) {\nreturn 42;   \n}\n}\n",
			formatted = SourceFormatter.format(formatSource, 2, true),
			expectedFormat = "function main():Int {\n  var text = \"{ literal }\"; // }\n  /* keep { } */\n  if (true) {\n    return 42;\n  }\n}\n";
		if (formatted != expectedFormat || SourceFormatter.format(formatted, 2, true) != formatted)
			throw "source formatting was not trivia-preserving and idempotent";
		var returnStart = formatSource.indexOf("return 42"), returnEnd = returnStart + "return 42;   ".length,
			rangeFormatted = SourceFormatter.format(formatSource, 2, true, returnStart, returnEnd);
		if (rangeFormatted == null || rangeFormatted.indexOf("\nvar text") < 0 || rangeFormatted.indexOf("\n    return 42;") < 0)
			throw "range formatting changed text outside the selected syntax line";
		var crlfSource = StringTools.replace(formatSource, "\n", "\r\n"), crlfFormatted = SourceFormatter.format(crlfSource, 2, true);
		if (crlfFormatted == null || crlfFormatted.indexOf("\r\n") < 0 || crlfFormatted.indexOf("\n") != crlfFormatted.indexOf("\r\n") + 1)
			throw "source formatting did not preserve CRLF line endings";
		if (SourceFormatter.format("function main(:Int {", 2, true) != null)
			throw "source formatting rewrote malformed input";
		var conditionalFormat = SourceFormatter.format("#if missing\nfunction main():Int return 1;\n#else\nfunction main():Int {\nreturn 2;\n}\n#end\n", 2, true);
		if (conditionalFormat == null || conditionalFormat.indexOf("#if missing") != 0 || conditionalFormat.indexOf("\n  return 2;") < 0)
			throw "source formatting did not preserve conditional compilation";
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
		var linkService = new LanguageService(), aliasSource = "import tools.Helper as H; function main():Int return 0;";
		linkService.update("tools/Helper.hx", "package tools; class Helper {}");
		linkService.update("AliasMain.hx", aliasSource);
		linkService.analyze("AliasMain");
		var links = linkService.documentLinks("AliasMain.hx");
		if (links.length != 1
			|| links[0].targetPath != "tools/Helper.hx"
			|| aliasSource.substring(links[0].span.start, links[0].span.end) != "tools.Helper")
			throw "language service did not resolve an aliased import's exact path span";
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
		var scopeCompletionService = new LanguageService(),
			scopeCompletionSource = "function main():Int { var value:Int = 1; if (true) { var value:String = \"inner\"; value; } return value; }";
		scopeCompletionService.update("ScopeCompletion.hx", scopeCompletionSource);
		scopeCompletionService.compile("ScopeCompletion");
		var innerCompletion = scopeCompletionService.complete("ScopeCompletion.hx", scopeCompletionSource.indexOf("value; }") + "value".length),
			outerCompletion = scopeCompletionService.complete("ScopeCompletion.hx", scopeCompletionSource.lastIndexOf("value;") + "value".length),
			innerDetail:Null<String> = null,
			outerDetail:Null<String> = null;
		for (item in innerCompletion)
			if (item.label == "value")
				innerDetail = item.detail;
		for (item in outerCompletion)
			if (item.label == "value")
				outerDetail = item.detail;
		if (innerDetail != "value:String" || outerDetail != "value:Int")
			throw "compiler completion context did not preserve lexical shadowing";
		var expectedService = new LanguageService(),
			expectedSource = "enum Choice { One; Two(value:Int); } function choose(candidate:Choice, count:Int):Choice return candidate; function main():Int return 0;";
		expectedService.update("Expected.hx", expectedSource);
		expectedService.compile("Expected");
		var expectedPosition = expectedSource.indexOf("return candidate") + "return ".length,
			expectedCompletion = expectedService.complete("Expected.hx", expectedPosition), candidateIndex = -1, oneIndex = -1, twoIndex = -1;
		for (index in 0...expectedCompletion.length)
			switch expectedCompletion[index].label {
				case "candidate":
					candidateIndex = index;
				case "One":
					oneIndex = index;
				case "Two":
					twoIndex = index;
				default:
			}
		if (candidateIndex < 0
			|| oneIndex <= candidateIndex
			|| twoIndex <= candidateIndex
			|| expectedCompletion[twoIndex].insertText != "Two("
			|| !StringTools.startsWith(expectedCompletion[candidateIndex].sortText, "0_"))
			throw "expected-type completion ranking or enum insertion failed";
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
		var enumService = new LanguageService();
		enumService.update("model/Kind.hx", "package model; enum Kind { One; Two(value:Int); }");
		var enumSource = "package app; import model.Kind; function read(value:Kind):Int return switch value { case Kind.One: 1; case Kind.Two(item): item; }; function main():Int { var first:Kind = Kind.One; var second:Kind = Kind.Two(41); return read(first) + read(second); }";
		enumService.update("app/Main.hx", enumSource);
		enumService.compile("app.Main");
		var importedEnumCompletion = enumService.complete("app/Main.hx", enumSource.indexOf("Kind.One") + "Kind.".length),
			hasImportedEnumCase = false;
		for (item in importedEnumCompletion)
			if (item.label == "Two")
				hasImportedEnumCase = true;
		if (!hasImportedEnumCase)
			throw "compiler completion context did not expose imported enum cases";
		var enumLiteralPosition = enumSource.lastIndexOf("Kind.One") + "Kind.".length,
			enumConstructorPosition = enumSource.lastIndexOf("Kind.Two") + "Kind.".length,
			enumDefinition = enumService.definition("app/Main.hx", enumLiteralPosition),
			enumReferences = enumService.references("app/Main.hx", enumLiteralPosition),
			enumRename = enumService.rename("app/Main.hx", enumConstructorPosition, "Pair");
		if (enumService.compiler.modules.get("app.Main").semanticModel.index.symbolIdAt(enumLiteralPosition) == null
			|| enumService.compiler.modules.get("app.Main").semanticModel.index.symbolIdAt(enumConstructorPosition) == null
			|| enumDefinition == null
			|| enumDefinition.path != "model/Kind.hx"
			|| enumReferences.length != 3
			|| enumRename.length != 3)
			throw "language service enum-case semantic indexing failed";
		var enumSignature = enumService.signatureHelp("app/Main.hx", enumSource.lastIndexOf("41") + 1);
		if (enumSignature == null || enumSignature.label != "Kind.Two(value:Int)" || enumSignature.activeParameter != 0)
			throw "language service enum-constructor signature help failed";
		var signatureService = new LanguageService(),
			signatureSource = "class Box { public function new(value:Int) {} } function add(left:Int, right:Int):Int return left + right; function main():Int { var box = new Box(1); return add(20, add(1, 2)); }";
		signatureService.update("Signatures.hx", signatureSource);
		signatureService.compile("Signatures");
		var nestedSignature = signatureService.signatureHelp("Signatures.hx", signatureSource.indexOf("2));") + 1),
			constructorSignature = signatureService.signatureHelp("Signatures.hx", signatureSource.indexOf("Box(1)") + "Box(".length);
		if (nestedSignature == null
			|| nestedSignature.label != "add(left:Int, right:Int):Int"
			|| nestedSignature.activeParameter != 1
			|| constructorSignature == null
			|| constructorSignature.label != "Box(value:Int)")
			throw "language service nested-call or constructor signature help failed";
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
			|| hierarchyService.compiler.modules.get("Hierarchy").semanticModel.index.symbolIdAt(aliasUse) == null
			|| inheritedDefinition == null
			|| inheritedDefinition.span.start > hierarchySource.indexOf("value")
			|| inheritedRename.length != 2
			|| aliasDefinition == null
			|| aliasDefinition.span.start > hierarchySource.indexOf("class Parent"))
			throw "language service did not resolve inheritance and alias navigation";
		var implementationService = new LanguageService(),
			contractSource = "package api; interface Plugin { function run():Int; }",
			baseSource = "package base; import api.Plugin; class Base implements Plugin { public function run():Int return 1; }",
			directSource = "package impl; import api.Plugin; class Direct implements Plugin { public function run():Int return 2; }",
			derivedSource = "package impl; import base.Base; class Derived extends Base { public function run():Int return 3; }",
			implementationMain = "package impl; import impl.Direct; import impl.Derived; function main():Int return new Direct().run() + new Derived().run();";
		implementationService.update("api/Plugin.hx", contractSource);
		implementationService.update("base/Base.hx", baseSource);
		implementationService.update("impl/Direct.hx", directSource);
		implementationService.update("impl/Derived.hx", derivedSource);
		implementationService.update("impl/Main.hx", implementationMain);
		implementationService.compile("impl.Main");
		var interfaceImplementations = implementationService.implementations("api/Plugin.hx", contractSource.indexOf("Plugin") + 2),
			methodImplementations = implementationService.implementations("api/Plugin.hx", contractSource.indexOf("run") + 1),
			baseImplementations = implementationService.implementations("base/Base.hx", baseSource.indexOf("Base") + 1),
			baseMethodImplementations = implementationService.implementations("base/Base.hx", baseSource.indexOf("run") + 1),
			leafImplementations = implementationService.implementations("impl/Direct.hx", directSource.indexOf("run") + 1);
		var implementationCancellation = new CancellationToken(), implementationCancelled = false;
		implementationCancellation.cancel();
		try implementationService.implementations("api/Plugin.hx", contractSource.indexOf("Plugin") + 2, implementationCancellation) catch (_:compiler.service.CancellationError)
			implementationCancelled = true;
		if (interfaceImplementations.length != 3
			|| methodImplementations.length != 3
			|| baseImplementations.length != 1
			|| baseImplementations[0].path != "impl/Derived.hx"
			|| baseMethodImplementations.length != 1
			|| baseMethodImplementations[0].path != "impl/Derived.hx"
			|| leafImplementations.length != 0
			|| !implementationCancelled)
			throw 'language service implementation navigation failed: interface=${interfaceImplementations.length}, method=${methodImplementations.length}, base=${baseImplementations.length}, override=${baseMethodImplementations.length}, leaf=${leafImplementations.length}';
		var hierarchyTypeService = new LanguageService(), rootTypeSource = "package types; class Root {}", namedTypeSource = "package types; interface Named {}",
			branchTypeSource = "package types; import types.Root; import types.Named; class Branch extends Root implements Named {}",
			leafTypeSource = "package types; import types.Branch; class Leaf extends Branch {}",
			detailedTypeSource = "package types; import types.Named; interface Detailed extends Named {}",
			typeHierarchyMain = "package app; import types.Root; import types.Named; import types.Branch; import types.Leaf; import types.Detailed; function main():Int return 0;";
		hierarchyTypeService.update("types/Root.hx", rootTypeSource);
		hierarchyTypeService.update("types/Named.hx", namedTypeSource);
		hierarchyTypeService.update("types/Branch.hx", branchTypeSource);
		hierarchyTypeService.update("types/Leaf.hx", leafTypeSource);
		hierarchyTypeService.update("types/Detailed.hx", detailedTypeSource);
		hierarchyTypeService.update("app/TypeHierarchy.hx", typeHierarchyMain);
		hierarchyTypeService.compile("app.TypeHierarchy");
		var preparedRoot = hierarchyTypeService.prepareTypeHierarchy("types/Root.hx", rootTypeSource.indexOf("Root") + 1),
			preparedBranch = hierarchyTypeService.prepareTypeHierarchy("types/Branch.hx", branchTypeSource.indexOf("Branch") + 1),
			preparedNamed = hierarchyTypeService.prepareTypeHierarchy("types/Named.hx", namedTypeSource.indexOf("Named") + 1);
		if (preparedRoot == null || preparedBranch == null || preparedNamed == null)
			throw "language service did not prepare type hierarchy items";
		var rootSubtypes = hierarchyTypeService.typeSubtypes(preparedRoot.identity, preparedRoot.revision),
			branchSupertypes = hierarchyTypeService.typeSupertypes(preparedBranch.identity, preparedBranch.revision),
			branchSubtypes = hierarchyTypeService.typeSubtypes(preparedBranch.identity, preparedBranch.revision),
			namedSubtypes = hierarchyTypeService.typeSubtypes(preparedNamed.identity, preparedNamed.revision);
		if (rootSubtypes.length != 1 || rootSubtypes[0].name != "Branch"
			|| branchSupertypes.length != 2 || branchSupertypes[0].name != "Named" || branchSupertypes[1].name != "Root"
			|| branchSubtypes.length != 1 || branchSubtypes[0].name != "Leaf"
			|| namedSubtypes.length != 2 || namedSubtypes[0].name != "Branch" || namedSubtypes[1].name != "Detailed")
			throw "language service type hierarchy did not return direct class and interface relationships";
		hierarchyTypeService.update("types/Root.hx", rootTypeSource + " ");
		if (hierarchyTypeService.isTypeHierarchyCurrent(preparedRoot.identity, preparedRoot.revision))
			throw "language service accepted a stale type hierarchy item";
		var typeService = new LanguageService();
		typeService.update("domain/Entity.hx", "package domain; class Entity {}");
		var typeSource = "package usecase; import domain.Entity; typedef EntityAlias = Entity; class Child extends Entity {} class Holder { public var entity:Entity; public function get():Entity return entity; } function identity(value:Entity):Entity return value; function main():Int return 0;";
		typeService.update("usecase/Main.hx", typeSource);
		typeService.compile("usecase.Main");
		var typePosition = typeSource.indexOf(":Entity return") + 1,
			typeDefinition = typeService.definition("usecase/Main.hx", typePosition),
			explicitTypeDefinition = typeService.typeDefinition("usecase/Main.hx", typePosition),
			valueTypeDefinition = typeService.typeDefinition("usecase/Main.hx", typeSource.indexOf("return value") + "return ".length),
			fieldTypeDefinition = typeService.typeDefinition("usecase/Main.hx", typeSource.indexOf("return entity") + "return ".length),
			methodTypeDefinition = typeService.typeDefinition("usecase/Main.hx", typeSource.indexOf("get():Entity") + 1),
			primitiveTypeDefinition = typeService.typeDefinition("usecase/Main.hx", typeSource.lastIndexOf("0")),
			typeReferences = typeService.references("usecase/Main.hx", typePosition),
			typeRename = typeService.rename("usecase/Main.hx", typePosition, "Record");
		if (typeService.compiler.modules.get("usecase.Main").semanticModel.index.symbolIdAt(typePosition) == null
			|| typeDefinition == null
			|| typeDefinition.path != "domain/Entity.hx"
			|| explicitTypeDefinition == null
			|| explicitTypeDefinition.path != "domain/Entity.hx"
			|| valueTypeDefinition == null
			|| valueTypeDefinition.path != "domain/Entity.hx"
			|| fieldTypeDefinition == null
			|| fieldTypeDefinition.path != "domain/Entity.hx"
			|| methodTypeDefinition == null
			|| methodTypeDefinition.path != "domain/Entity.hx"
			|| primitiveTypeDefinition != null
			|| typeReferences.length != 8
			|| typeRename.length != 8)
			throw 'language service type-reference index failed: explicit=${explicitTypeDefinition != null}, value=${valueTypeDefinition != null}, field=${fieldTypeDefinition != null}, method=${methodTypeDefinition != null}, primitive=${primitiveTypeDefinition != null}, references=${typeReferences.length}, rename=${typeRename.length}';
		var collisionService = new LanguageService(),
			collisionSource = "class Item { public function value():Int return 1; public function score():Int return value(); } function main():Int return new Item().value();";
		collisionService.update("Collision.hx", collisionSource);
		collisionService.compile("Collision");
		var collisionPosition = collisionSource.lastIndexOf("value") + 2;
		if (collisionService.rename("Collision.hx", collisionPosition, "score").length != 0
			|| collisionService.rename("Collision.hx", collisionPosition, "not-valid").length != 0)
			throw "language service allowed an unsafe rename";
		var inheritedCollisionService = new LanguageService(),
			inheritedCollisionSource = "class Parent { public function value():Int return 1; public function score():Int return 2; } class Child extends Parent {} function main():Int return new Child().value();";
		inheritedCollisionService.update("InheritedCollision.hx", inheritedCollisionSource);
		inheritedCollisionService.compile("InheritedCollision");
		if (inheritedCollisionService.rename("InheritedCollision.hx", inheritedCollisionSource.lastIndexOf("value") + 1, "score").length != 0)
			throw "language service allowed an inherited-member rename collision";
		var scopedRenameService = new LanguageService(),
			scopedRenameSource = "function first(value:Int):Int return value; function second(item:Int):Int return item; function main():Int return first(42) + second(1);";
		scopedRenameService.update("ScopedRename.hx", scopedRenameSource);
		scopedRenameService.compile("ScopedRename");
		var scopedRenamePosition = scopedRenameSource.indexOf("return value") + "return ".length;
		if (scopedRenameService.rename("ScopedRename.hx", scopedRenamePosition, "item").length != 2)
			throw "language service treated another function's local as a rename collision";
		var globalCollisionService = new LanguageService();
		globalCollisionService.update("lib/Math.hx",
			"package lib; function add(left:Int, right:Int):Int return left + right; function sum(left:Int, right:Int):Int return left + right;");
		var globalCollisionSource = "package app; import lib.Math; function main():Int return Math.add(20, 22);";
		globalCollisionService.update("app/Collision.hx", globalCollisionSource);
		globalCollisionService.compile("app.Collision");
		if (globalCollisionService.rename("app/Collision.hx", globalCollisionSource.indexOf("add") + 1, "sum").length != 0)
			throw "language service allowed a cross-module global rename collision";
		if (enumService.rename("app/Main.hx", enumConstructorPosition, "One").length != 0)
			throw "language service allowed an enum-case rename collision";
		var incrementalService = new LanguageService();
		incrementalService.update("inc/Values.hx", "package inc; function value():Int return 1;");
		var incrementalSource = "package incapp; import inc.Values; function helper():Int return Values.value(); function main():Int return helper();";
		incrementalService.update("incapp/Main.hx", incrementalSource);
		incrementalService.compile("incapp.Main");
		var valuesIndex = incrementalService.compiler.modules.get("inc.Values").semanticModel.index,
			firstMainIndex = incrementalService.compiler.modules.get("incapp.Main").semanticModel.index;
		incrementalService.update("incapp/Main.hx",
			"package incapp; import inc.Values; function helper():Int return Values.value() + 1; function main():Int return helper();");
		var bodyAnalysis = incrementalService.compile("incapp.Main"),
			secondMainIndex = incrementalService.compiler.modules.get("incapp.Main").semanticModel.index,
			helperUse = incrementalService.compiler.modules.get("incapp.Main").source.text.lastIndexOf("helper");
		if (valuesIndex != incrementalService.compiler.modules.get("inc.Values").semanticModel.index
			|| firstMainIndex == secondMainIndex
			|| secondMainIndex.revision != incrementalService.compiler.modules.get("incapp.Main").revision
			|| secondMainIndex.symbolIdAt(helperUse) == null
			|| bodyAnalysis.retyped.indexOf("incapp.Main.helper") < 0
			|| bodyAnalysis.retyped.indexOf("main") < 0)
			throw "semantic index did not rebuild exactly the edited module";
		incrementalService.update("inc/Values.hx", "package inc; function value():Int return 2;");
		var dependencyBodyAnalysis = incrementalService.compile("incapp.Main");
		if (dependencyBodyAnalysis.retyped.indexOf("main") >= 0 || dependencyBodyAnalysis.retyped.indexOf("incapp.Main.helper") >= 0)
			throw "body-only dependency edit unnecessarily rebuilt consumer indexes";
		var structuralService = new LanguageService();
		structuralService.update("shape/Choice.hx", "package shape; enum Choice { One; }");
		var structuralSource = "package shapeapp; import shape.Choice; function helper(value:Choice):Int return switch value { case Choice.One: 1; default: 0; }; function main():Int return helper(Choice.One);";
		structuralService.update("shapeapp/Main.hx", structuralSource);
		structuralService.compile("shapeapp.Main");
		var originalConsumerIndex = structuralService.compiler.modules.get("shapeapp.Main").semanticModel.index;
		structuralService.update("shape/Choice.hx", "package shape; enum Choice { One; Two; }");
		var structuralAnalysis = structuralService.compile("shapeapp.Main"),
			updatedConsumerIndex = structuralService.compiler.modules.get("shapeapp.Main").semanticModel.index,
			choiceUse = structuralSource.lastIndexOf("Choice.One") + "Choice.".length;
		if (structuralAnalysis.retyped.indexOf("main") < 0
			|| structuralAnalysis.retyped.indexOf("shapeapp.Main.helper") < 0
			|| originalConsumerIndex == updatedConsumerIndex
			|| updatedConsumerIndex.symbolIdAt(choiceUse) == null)
			throw "public enum change did not atomically rebuild dependent semantic indexes";
		var largeService = new LanguageService(),
			largeSource = new StringBuf();
		for (index in 0...260)
			largeSource.add('function candidate${StringTools.lpad(Std.string(index), "0", 3)}():Int return $index; ');
		largeSource.add("function main():Int return 0;");
		var largeText = largeSource.toString();
		largeService.update("Large.hx", largeText);
		largeService.compile("Large");
		var largeCompletionResult = largeService.completeResult("Large.hx", largeText.length),
			firstLargeCompletion = largeCompletionResult.items,
			secondLargeCompletion = largeService.complete("Large.hx", largeText.length);
		if (!largeCompletionResult.isIncomplete || firstLargeCompletion.length != 200 || secondLargeCompletion.length != firstLargeCompletion.length)
			throw 'completion result limit was not enforced: ${firstLargeCompletion.length}';
		for (index in 0...firstLargeCompletion.length)
			if (firstLargeCompletion[index].label != secondLargeCompletion[index].label)
				throw "bounded completion ordering was not deterministic";
		var largeIndex = largeService.compiler.modules.get("Large").semanticModel.index;
		if (largeIndex.indexingMs < 0)
			throw "semantic indexing timing was not recorded";
		var cancelled = new CancellationToken();
		cancelled.cancel();
		var completionCancelled = false, referencesCancelled = false;
		try
			largeService.complete("Large.hx", largeText.length, cancelled)
		catch (_:compiler.service.CancellationError)
			completionCancelled = true;
		try
			service.references("Main.hx", methodPosition, cancelled)
		catch (_:compiler.service.CancellationError)
			referencesCancelled = true;
		if (!completionCancelled || !referencesCancelled)
			throw "language-service queries ignored cancellation";
		var configuredService = new LanguageService();
		configuredService.update("Configured.hx", "function main():Int return 42;");
		configuredService.analyze("Configured");
		var defaultIndex = configuredService.compiler.modules.get("Configured").semanticModel.index;
		configuredService.configure("build-a", "scope-a", []);
		if (configuredService.compiler.configurationIdentity != "build-a" || configuredService.isCurrent("Configured.hx"))
			throw "compiler build identity did not invalidate semantic caches";
		configuredService.analyze("Configured");
		if (defaultIndex == configuredService.compiler.modules.get("Configured").semanticModel.index)
			throw "semantic index was reused across build configurations";
		var defineService = new LanguageService();
		defineService.update("Stable.hx", "function stable():Int return 1;");
		defineService.update("Conditional.hx",
			"import Stable;\n#if feature && version >= 2.5\nfunction featureOnly():Int return Stable.stable();\n#else\nfunction fallbackOnly():Int return Stable.stable();\n#end\nfunction main():Int return Stable.stable();");
		defineService.configure("without-feature", "shared-scope", []);
		defineService.analyze("Conditional");
		var stableIndex = defineService.compiler.modules.get("Stable").semanticModel.index,
			hasFallback = false;
		for (symbol in defineService.documentSymbols("Conditional.hx"))
			if (symbol.name == "fallbackOnly")
				hasFallback = true;
		defineService.configure("with-feature", "shared-scope", ["feature", "version=3.0"]);
		if (!defineService.isCurrent("Stable.hx") || defineService.isCurrent("Conditional.hx"))
			throw "define change invalidated modules that do not reference it";
		defineService.analyze("Conditional");
		var hasFeature = false;
		for (symbol in defineService.documentSymbols("Conditional.hx"))
			if (symbol.name == "featureOnly")
				hasFeature = true;
		if (!hasFallback || !hasFeature || stableIndex != defineService.compiler.modules.get("Stable").semanticModel.index)
			throw "conditional compilation did not switch branches incrementally";
		var malformedConditional = new LanguageService();
		malformedConditional.update("MalformedConditional.hx", "#if feature\nfunction main():Int return 1;");
		try {
			malformedConditional.analyze("MalformedConditional");
			throw "unclosed conditional compilation unexpectedly parsed";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E0002")
				throw error;
		}
		service.update("Main.hx", "function main(:Int { return 0; }");
		try {
			service.compile("Main");
			throw "invalid edit unexpectedly compiled";
		} catch (error:CompileError) {}
		var recoveredSymbols = service.documentSymbols("Main.hx"),
			recoveredCompletion = service.complete("Main.hx", 0),
			staleRename = service.rename("Main.hx", methodPosition, "display");
		if (recoveredSymbols.length == 0 || recoveredCompletion.length == 0)
			throw "failed edit discarded the last good language-service snapshot";
		if (!recoveredSymbols[0].stale || recoveredSymbols[0].revision != 1 || !recoveredCompletion[0].stale)
			throw "failed edit did not identify stale semantic query results";
		if (staleRename.length != 2 || !staleRename[0].stale || !staleRename[1].stale)
			throw "rename did not preserve last-good semantic snapshot metadata";
		var partialService = new LanguageService();
		partialService.update("Partial.hx",
			"function broken(:Int {} function alsoBroken(:Int {} function visible():Int return 42;");
		try {
			partialService.analyze("Partial");
			throw "invalid partial source unexpectedly analyzed";
		} catch (_:CompileError) {}
		var partialSymbols = partialService.documentSymbols("Partial.hx"), foundVisible = false;
		for (symbol in partialSymbols)
			if (symbol.name == "visible" && symbol.stale)
				foundVisible = true;
		if (!foundVisible)
			throw "parser recovery did not preserve a valid declaration after malformed declarations";
		if (partialService.diagnostics("Partial.hx").length != 2)
			throw "parser recovery did not collect multiple declaration diagnostics";
		var delimiterService = new LanguageService();
		delimiterService.update("Delimiter.hx", "function first():Int return 1 function second():Int return 2;");
		try {
			delimiterService.analyze("Delimiter");
			throw "missing delimiter unexpectedly analyzed";
		} catch (_:CompileError) {}
		var delimiterSymbols = delimiterService.documentSymbols("Delimiter.hx"), delimiterDiagnostics = delimiterService.diagnostics("Delimiter.hx");
		if (delimiterSymbols.length != 2 || delimiterSymbols[0].name != "first" || delimiterSymbols[1].name != "second")
			throw "missing semicolon recovery did not retain adjacent declarations";
		if (delimiterDiagnostics.length != 1 || delimiterDiagnostics[0].fixes.length != 1
			|| delimiterDiagnostics[0].fixes[0].edits[0].replacement != ";")
			throw "missing semicolon recovery did not expose a deterministic fix";
		var signatureService = new LanguageService();
		signatureService.update("Signature.hx", "function pending(");
		try
			signatureService.analyze("Signature")
		catch (_:CompileError) {}
		var signatureSymbols = signatureService.documentSymbols("Signature.hx");
		if (signatureSymbols.length != 1 || signatureSymbols[0].name != "pending")
			throw "unfinished function signature did not produce a recovered declaration";
		var memberService = new LanguageService();
		memberService.update("Members.hx", "class Members { function broken(:Int {} function visible():Int return 42; }");
		try
			memberService.analyze("Members")
		catch (_:CompileError) {}
		var memberSymbols = memberService.documentSymbols("Members.hx"), foundMethod = false;
		for (symbol in memberSymbols)
			if (symbol.name == "visible")
				foundMethod = true;
		if (!foundMethod)
			throw "class-member recovery discarded a valid method after a malformed method";
		var statementService = new LanguageService();
		statementService.update("Statements.hx", "function retained():Int { var broken = ; return 42; }");
		try
			statementService.analyze("Statements")
		catch (_:CompileError) {}
		var statementSymbols = statementService.documentSymbols("Statements.hx");
		if (statementSymbols.length != 1 || statementSymbols[0].name != "retained")
			throw "statement recovery discarded its enclosing function";
		var expressionService = new LanguageService();
		var expressionSource = "function pending(argument:Int):Int { var available:String = \"ok\"; var incomplete =";
		expressionService.update("Expression.hx", expressionSource);
		try
			expressionService.analyze("Expression")
		catch (_:CompileError) {}
		var expressionSymbols = expressionService.documentSymbols("Expression.hx"), expressionCompletion = expressionService.complete("Expression.hx",
			expressionSource.length), completionNames = [for (item in expressionCompletion) item.label];
		if (expressionSymbols.length != 1 || expressionSymbols[0].name != "pending")
			throw "incomplete expression discarded its enclosing declaration";
		if (completionNames.indexOf("argument") < 0 || completionNames.indexOf("available") < 0)
			throw "recovered expression completion omitted current arguments or locals";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}
}
