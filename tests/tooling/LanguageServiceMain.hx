import compiler.service.LanguageService;
import compiler.service.LanguageService.DocumentSymbol;
import compiler.service.CancellationToken;
import compiler.service.SourceFormatter;
import compiler.service.EditorSnapshot.EditorSnapshotConfidence;
import compiler.Diagnostic.CompileError;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedExpressionKind;

class LanguageServiceMain {
	static function main():Void {
		var formatSource = "function main():Int {\nvar text = \"{ literal }\"; // }\n/* keep { } */\nif (true) {\nreturn 42;   \n}\n}\n",
			formatted = SourceFormatter.format(formatSource, 2, true),
			expectedFormat = "function main():Int {\n  var text = \"{ literal }\"; // }\n  /* keep { } */\n  if (true) {\n    return 42;\n  }\n}\n";
		if (formatted != expectedFormat || SourceFormatter.format(formatted, 2, true) != formatted)
			throw "source formatting was not trivia-preserving and idempotent";
		var returnStart = formatSource.indexOf("return 42"),
			returnEnd = returnStart + "return 42;   ".length,
			rangeFormatted = SourceFormatter.format(formatSource, 2, true, returnStart, returnEnd);
		if (rangeFormatted == null || rangeFormatted.indexOf("\nvar text") < 0 || rangeFormatted.indexOf("\n    return 42;") < 0)
			throw "range formatting changed text outside the selected syntax line";
		var crlfSource = StringTools.replace(formatSource, "\n", "\r\n"),
			crlfFormatted = SourceFormatter.format(crlfSource, 2, true);
		if (crlfFormatted == null || crlfFormatted.indexOf("\r\n") < 0 || crlfFormatted.indexOf("\n") != crlfFormatted.indexOf("\r\n") + 1)
			throw "source formatting did not preserve CRLF line endings";
		if (SourceFormatter.format("function main(:Int {", 2, true) != null)
			throw "source formatting rewrote malformed input";
		var conditionalFormat = SourceFormatter.format("#if missing\nfunction main():Int return 1;\n#else\nfunction main():Int {\nreturn 2;\n}\n#end\n", 2,
			true);
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
		var linkService = new LanguageService(),
			aliasSource = "import tools.Helper as H; function main():Int return 0;";
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
		if (!hasActive || service.hover("Main.hx", instanceHoverPosition) != "Editor.active:Int")
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
		var importedMemberSource = "package editor; import editor.util.Math; function main():Int { return Math.";
		importService.update("editor/Main.hx", importedMemberSource);
		var importedMemberCompletion = importService.completeResult("editor/Main.hx", importedMemberSource.length),
			hasImportedMember = false;
		for (item in importedMemberCompletion.items)
			if (item.label == "add" && item.detail == "add(Int,Int):Int")
				hasImportedMember = true;
		if (!hasImportedMember || !importedMemberCompletion.isIncomplete)
			throw "recovered imported module completion failed";
		var importedClassSource = "package editor.util; class Base { public var inherited:Int; } class Widget extends Base { public var ready:Int; public static function create():Widget return new Widget(); public function reset(value:Int):Void return; } function main():Void return;";
		importService.update("editor/util/Widget.hx", importedClassSource);
		var importedClassRecoverySource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); widget.";
		importService.update("editor/ClassMain.hx", importedClassRecoverySource);
		var importedClassCompletion = importService.complete("editor/ClassMain.hx", importedClassRecoverySource.length),
			hasImportedField = false,
			hasImportedMethod = false;
		for (item in importedClassCompletion) {
			if (item.label == "ready")
				hasImportedField = true;
			if (item.label == "reset")
				hasImportedMethod = true;
		}
		if (!hasImportedField || !hasImportedMethod)
			throw "recovered imported class typing did not expose instance members";
		var importedStaticRecoverySource = "package editor; import editor.util.Widget; function main():Void { return Widget.";
		importService.update("editor/StaticClassMain.hx", importedStaticRecoverySource);
		var importedStaticCompletion = importService.complete("editor/StaticClassMain.hx", importedStaticRecoverySource.length),
			hasImportedStaticMethod = false;
		for (item in importedStaticCompletion)
			if (item.label == "create")
				hasImportedStaticMethod = true;
		if (!hasImportedStaticMethod)
			throw "recovered imported class typing did not expose static members";
		var wildcardStaticRecoverySource = "package editor; import editor.util.*; function main():Void { return Widget.";
		importService.update("editor/WildcardStaticMain.hx", wildcardStaticRecoverySource);
		var wildcardStaticCompletion = importService.complete("editor/WildcardStaticMain.hx", wildcardStaticRecoverySource.length),
			hasWildcardStaticMethod = false;
		for (item in wildcardStaticCompletion)
			if (item.label == "create")
				hasWildcardStaticMethod = true;
		if (!hasWildcardStaticMethod)
			throw "recovered wildcard import did not expose static members";
		var importedTypedSource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); return; }";
		importService.update("editor/TypedClassMain.hx", importedTypedSource);
		var importedTypedModel = importService.compiler.modules.get("editor.TypedClassMain").recoveredSemanticModel,
			importedConstructorType = false;
		if (importedTypedModel != null && importedTypedModel.partialTypedProgram != null)
			for (fn in importedTypedModel.partialTypedProgram.functions)
				for (statement in fn.statements)
					switch statement {
						case TVar(_, initializer, _):
							switch initializer.type {
								case TInstance(NominalKind.Class, "Widget", _): importedConstructorType = true;
								default:
							}
						default:
					}
		if (!importedConstructorType)
			throw "recovered typing did not resolve a class imported from another editor module";
		var importedSignatureSource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); widget.reset(";
		importService.update("editor/ImportedSignature.hx", importedSignatureSource);
		var importedSignature = importService.signatureHelp("editor/ImportedSignature.hx", importedSignatureSource.length);
		if (importedSignature == null || importedSignature.label != "reset(value:Int):Void" || importedSignature.activeParameter != 0)
			throw "recovered signature help did not use an imported module's temporary signature";
		var importedArgumentContext = importService.completionContext("editor/ImportedSignature.hx", importedSignatureSource.length);
		if (importedArgumentContext == null || importedArgumentContext.context.expected != TInt)
			throw "recovered imported signature did not preserve the expected argument type";
		var inferredExternalService = new LanguageService();
		inferredExternalService.update("editor/util/Inferred.hx", "package editor.util; function value() return \"known\";");
		var inferredExternalSource = "package editor; import editor.util.Inferred; function main():String { return value(); }";
		inferredExternalService.update("editor/InferredMain.hx", inferredExternalSource);
		var inferredExternalModel = inferredExternalService.compiler.modules.get("editor.InferredMain").recoveredSemanticModel,
			inferredExternalResult = false;
		if (inferredExternalModel != null && inferredExternalModel.partialTypedProgram != null)
			for (fn in inferredExternalModel.partialTypedProgram.functions)
				for (statement in fn.statements)
					switch statement {
						case TReturn(expression, _):
							if (expression.type == compiler.types.Type.CompilerType.TString)
								inferredExternalResult = true;
						default:
					}
		if (!inferredExternalResult)
			throw "recovered typing did not infer an external function's result type";
		var inferredCompletionSource = "package editor; import editor.util.Inferred; function main():String { return val";
		inferredExternalService.update("editor/InferredCompletion.hx", inferredCompletionSource);
		var inferredCompletion = inferredExternalService.completeResult("editor/InferredCompletion.hx", inferredCompletionSource.length),
			hasRecoveredImportedFunction = false;
		for (item in inferredCompletion.items)
			if (item.label == "value" && item.detail == "value():String")
				hasRecoveredImportedFunction = true;
		if (!hasRecoveredImportedFunction || !inferredCompletion.isIncomplete)
			throw "completion did not expose a recovered imported function";
		var inferredQualifiedSource = "package editor; import editor.util.Inferred; function main():Void { return Inferred.";
		inferredExternalService.update("editor/InferredQualifiedCompletion.hx", inferredQualifiedSource);
		var inferredQualifiedCompletion = inferredExternalService.completeResult("editor/InferredQualifiedCompletion.hx", inferredQualifiedSource.length),
			hasRecoveredQualifiedFunction = false;
		for (item in inferredQualifiedCompletion.items)
			if (item.label == "value" && item.detail == "value():String")
				hasRecoveredQualifiedFunction = true;
		if (!hasRecoveredQualifiedFunction || !inferredQualifiedCompletion.isIncomplete)
			throw "qualified completion did not expose an inferred recovered function";
		inferredExternalService.update("editor/util/Inferred.hx", "package editor.util; function value() return 1;");
		var inferredUpdatedSource = "package editor; import editor.util.Inferred; function main():Void { return Inferred.";
		inferredExternalService.update("editor/InferredQualifiedUpdated.hx", inferredUpdatedSource);
		var inferredUpdatedCompletion = inferredExternalService.completeResult("editor/InferredQualifiedUpdated.hx", inferredUpdatedSource.length),
			hasUpdatedRecoveredQualifiedFunction = false;
		for (item in inferredUpdatedCompletion.items)
			if (item.label == "value" && item.detail == "value():Int")
				hasUpdatedRecoveredQualifiedFunction = true;
		if (!hasUpdatedRecoveredQualifiedFunction)
			throw "qualified completion reused an inferred signature from an older dependency revision";
		var recoveredTypeCompletionSource = "package editor; import editor.util.Widget; function main():Void { var item:Wid";
		importService.update("editor/RecoveredTypeCompletion.hx", recoveredTypeCompletionSource);
		var recoveredTypeCompletion = importService.completeResult("editor/RecoveredTypeCompletion.hx", recoveredTypeCompletionSource.length),
			hasRecoveredImportedType = false;
		for (item in recoveredTypeCompletion.items)
			if (item.label == "Widget" && item.kind == "class")
				hasRecoveredImportedType = true;
		if (!hasRecoveredImportedType || !recoveredTypeCompletion.isIncomplete)
			throw "type completion did not expose a recovered imported class";
		var recoveredWildcardTypeSource = "package editor; import editor.util.*; function main():Void { var item:Wid";
		importService.update("editor/RecoveredWildcardTypeCompletion.hx", recoveredWildcardTypeSource);
		var recoveredWildcardTypeCompletion = importService.completeResult("editor/RecoveredWildcardTypeCompletion.hx", recoveredWildcardTypeSource.length),
			hasRecoveredWildcardType = false;
		for (item in recoveredWildcardTypeCompletion.items)
			if (item.label == "Widget" && item.kind == "class")
				hasRecoveredWildcardType = true;
		if (!hasRecoveredWildcardType)
			throw "wildcard type completion did not expose a recovered imported class";
		var recoveredImportService = new LanguageService();
		recoveredImportService.update("recovered/lib/Widget.hx", "package recovered.lib; class Widget {}");
		var recoveredImportSource = "package recovered; import recovered.lib.Wid";
		recoveredImportService.update("recovered/Main.hx", recoveredImportSource);
		var recoveredImportCompletion = recoveredImportService.completeResult("recovered/Main.hx", recoveredImportSource.length),
			hasRecoveredImport = false;
		for (item in recoveredImportCompletion.items)
			if (item.label == "Widget" && item.kind == "class" && item.identity == null)
				hasRecoveredImport = true;
		if (!hasRecoveredImport || !recoveredImportCompletion.isIncomplete)
			throw "import completion did not expose an editor-only recovered declaration";
		var wildcardTypingService = new LanguageService();
		wildcardTypingService.update("wild/lib/Widget.hx", "package wild.lib; class Widget { public var known:Int; }");
		var wildcardTypingSource = "package wild; import wild.lib.*; function main():Void { var widget:Widget = new Widget(); widget.";
		wildcardTypingService.update("wild/Main.hx", wildcardTypingSource);
		var wildcardTypingNames = [for (item in wildcardTypingService.complete("wild/Main.hx", wildcardTypingSource.length)) item.label];
		if (wildcardTypingNames.indexOf("known") < 0)
			throw "wildcard-imported recovered type did not retain its member completion";
		var transitiveService = new LanguageService();
		transitiveService.update("editor/base/Base.hx",
			"package editor.base; class Base { public var inherited:Int; public function inheritedMethod(value:String):String return value; }");
		transitiveService.update("editor/util/Widget.hx", "package editor.util; import editor.base.Base; class Widget extends Base {}");
		var transitiveSource = "package editor; import editor.util.Widget; function main() { var widget:Widget = new Widget(); return widget.inherited; }";
		transitiveService.update("editor/Transitive.hx", transitiveSource);
		var transitiveModel = transitiveService.compiler.modules.get("editor.Transitive").recoveredSemanticModel,
			transitiveInheritedType = false;
		if (transitiveModel != null && transitiveModel.partialTypedProgram != null)
			for (fn in transitiveModel.partialTypedProgram.functions)
				for (statement in fn.statements)
					switch statement {
						case TReturn(expression, _):
							if (expression.type == TInt)
								transitiveInheritedType = true;
						default:
					}
		if (!transitiveInheritedType)
			throw "recovered typing did not follow an imported module's inherited declaration closure";
		var inheritedSignatureSource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); widget.inheritedMethod(";
		transitiveService.update("editor/InheritedSignature.hx", inheritedSignatureSource);
		var inheritedSignature = transitiveService.signatureHelp("editor/InheritedSignature.hx", inheritedSignatureSource.length);
		if (inheritedSignature == null
			|| inheritedSignature.label != "inheritedMethod(value:String):String"
			|| inheritedSignature.activeParameter != 0)
			throw "recovered signature help did not follow an imported inherited method";
		for (unresolved in transitiveService.unresolvedSymbols("editor/Transitive.hx"))
			if (unresolved.name == "inherited")
				throw "recovered known inherited member was incorrectly reported as unresolved";
		var refreshedClosureService = new LanguageService();
		refreshedClosureService.update("editor/base/Base.hx", "package editor.base; class Base { public var inherited:Int; }");
		refreshedClosureService.update("editor/util/Widget.hx", "package editor.util; import editor.base.Base; class Widget extends Base {}");
		refreshedClosureService.update("editor/Transitive.hx", transitiveSource);
		refreshedClosureService.update("editor/base/Base.hx", "package editor.base; class Base { public var inherited:String; }");
		refreshedClosureService.update("editor/Transitive.hx", transitiveSource);
		var refreshedModel = refreshedClosureService.compiler.modules.get("editor.Transitive").recoveredSemanticModel,
			retainedOldInheritedType = false,
			refreshedTypes:Array<String> = [];
		if (refreshedModel != null && refreshedModel.partialTypedProgram != null)
			for (fn in refreshedModel.partialTypedProgram.functions)
				for (statement in fn.statements)
					switch statement {
						case TReturn(expression, _):
							refreshedTypes.push(Std.string(expression.type));
							if (expression.type == TInt)
								retainedOldInheritedType = true;
						default:
					}
		if (retainedOldInheritedType)
			throw 'recovered typing reused a stale transitive declaration after dependency update: ${refreshedTypes.join(",")}';
		var diagnosticRefreshService = new LanguageService();
		diagnosticRefreshService.update("editor/base/Base.hx", "package editor.base; class Base { public var inherited:String; }");
		diagnosticRefreshService.update("editor/util/Widget.hx", "package editor.util; import editor.base.Base; class Widget extends Base {}");
		var diagnosticSource = "package editor; import editor.util.Widget; function main():Int { var widget:Widget = new Widget(); return widget.inherited; }";
		diagnosticRefreshService.update("editor/Diagnostic.hx", diagnosticSource);
		if (diagnosticRefreshService.diagnostics("editor/Diagnostic.hx").length == 0)
			throw "recovered typing did not publish the initial dependent type diagnostic";
		diagnosticRefreshService.update("editor/base/Base.hx", "package editor.base; class Base { public var inherited:Int; }");
		if (diagnosticRefreshService.diagnostics("editor/Diagnostic.hx").length != 0)
			throw "dependency recovery retained a stale semantic diagnostic";
		importService.analyze("editor.util.Widget");
		var importedMemberUseSource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); widget.ready; }";
		importService.update("editor/ClassMain.hx", importedMemberUseSource);
		var importedMemberUse = importedMemberUseSource.lastIndexOf("ready"),
			importedMemberDefinition = importService.definition("editor/ClassMain.hx", importedMemberUse + 1),
			importedMemberReferences = importService.references("editor/ClassMain.hx", importedMemberUse + 1);
		if (importedMemberDefinition == null
			|| importedMemberDefinition.path != "editor/util/Widget.hx"
			|| importedMemberReferences.length != 2)
			throw "recovered imported class member navigation did not use the authoritative identity";
		var importedInheritedUseSource = "package editor; import editor.util.Widget; function main():Void { var widget:Widget = new Widget(); widget.inherited; }";
		importService.update("editor/InheritedMain.hx", importedInheritedUseSource);
		var importedInheritedUse = importedInheritedUseSource.lastIndexOf("inherited"),
			importedInheritedDefinition = importService.definition("editor/InheritedMain.hx", importedInheritedUse + 1);
		if (importedInheritedDefinition == null || importedInheritedDefinition.path != "editor/util/Widget.hx")
			throw "recovered imported inherited member navigation did not resolve through the workspace";
		var importedInheritedContext = importService.completionContext("editor/InheritedMain.hx", importedInheritedUse + 1);
		if (importedInheritedContext == null
			|| importedInheritedContext.confidence != EditorSnapshotConfidence.RecoveredStable
			|| !importedInheritedContext.identityTrusted)
			throw "recovered authoritative member identity was not marked stable";
		var aliasedMemberSource = "package editor; import editor.util.Math as M; function main():Int { return M.";
		importService.update("editor/Main.hx", aliasedMemberSource);
		var aliasedMemberCompletion = importService.complete("editor/Main.hx", aliasedMemberSource.length),
			hasAliasedMember = false;
		for (item in aliasedMemberCompletion)
			if (item.label == "add")
				hasAliasedMember = true;
		if (!hasAliasedMember)
			throw "recovered aliased module completion failed";
		var importedRecoverySource = "package editor; import editor.util.Math; function main():Int { return Math.add(20,";
		importService.update("editor/Main.hx", importedRecoverySource);
		var importedRecoveryPosition = importedRecoverySource.lastIndexOf("add") + 1,
			importedRecoveryDefinition = importService.definition("editor/Main.hx", importedRecoveryPosition),
			importedRecoveryReferences = importService.references("editor/Main.hx", importedRecoveryPosition);
		var staleCurrentReference = false;
		for (reference in importedRecoveryReferences)
			if (reference.path == "editor/Main.hx" && reference.stale)
				staleCurrentReference = true;
		if (importedRecoveryDefinition == null
			|| importedRecoveryDefinition.path != "editor/util/Math.hx"
			|| importedRecoveryReferences.length != 2
			|| staleCurrentReference)
			throw "recovered imported symbol resolution failed";
		var crossModuleReferenceService = new LanguageService(),
			crossModuleTarget = "package refs; class Target { public function value():Int return 1; }",
			crossModuleConsumer = "package refs; import refs.Target; class Consumer { public function read(target:Target):Int return target.value(); } function main():Int return 0;";
		crossModuleReferenceService.update("refs/Target.hx", crossModuleTarget);
		crossModuleReferenceService.update("refs/Consumer.hx", crossModuleConsumer);
		crossModuleReferenceService.compile("refs.Consumer");
		var brokenCrossModuleTarget = "package refs; class Target { public function value():Int { var broken = ; return 1; } }";
		crossModuleReferenceService.update("refs/Target.hx", brokenCrossModuleTarget);
		var crossModuleReferences = crossModuleReferenceService.references("refs/Target.hx", brokenCrossModuleTarget.indexOf("value") + 1),
			crossModuleConsumerReference = false;
		for (reference in crossModuleReferences)
			if (reference.path == "refs/Consumer.hx")
				crossModuleConsumerReference = true;
		if (!crossModuleConsumerReference || crossModuleReferences.length < 2)
			throw 'recovered declaration dropped authoritative cross-module references: ${[for (reference in crossModuleReferences) reference.path].join(", ")}';
		var recoveredConsumer = "package refs; import refs.Target; class Consumer { public function read(target:Target):Int { broken = ; return target.value(); } } function main():Int return 0;";
		crossModuleReferenceService.update("refs/Consumer.hx", recoveredConsumer);
		var currentTargetReferences = crossModuleReferenceService.references("refs/Target.hx", crossModuleTarget.indexOf("value") + 1),
			currentConsumerReference = false;
		for (reference in currentTargetReferences)
			if (reference.path == "refs/Consumer.hx" && !reference.stale)
				currentConsumerReference = true;
		if (!currentConsumerReference)
			throw 'authoritative references did not include a current recovered consumer: ${[for (reference in currentTargetReferences) reference.path].join(", ")}';
		var exactTargetReferenceService = new LanguageService(),
			exactConsumer = "package refs; import refs.Target; class Consumer { public function read(target:Target):Int return target.value(); } function main():Int return 0;";
		exactTargetReferenceService.update("refs/Target.hx", crossModuleTarget);
		exactTargetReferenceService.update("refs/Consumer.hx", exactConsumer);
		exactTargetReferenceService.compile("refs.Consumer");
		exactTargetReferenceService.update("refs/Consumer.hx", recoveredConsumer);
		var exactTargetReferences = exactTargetReferenceService.references("refs/Target.hx", crossModuleTarget.indexOf("value") + 1),
			exactConsumerReference = false;
		for (reference in exactTargetReferences)
			if (reference.path == "refs/Consumer.hx" && !reference.stale)
				exactConsumerReference = true;
		if (!exactConsumerReference || exactTargetReferenceService.rename("refs/Target.hx", crossModuleTarget.indexOf("value") + 1, "renamed").length != 0)
			throw "rename crossed into a recovered consumer snapshot";
		var aliasedRecoverySource = "package editor; import editor.util.Math as M; function main():Int { return M.add(20,";
		importService.update("editor/Main.hx", aliasedRecoverySource);
		var aliasedRecoveryPosition = aliasedRecoverySource.lastIndexOf("add") + 1,
			aliasedRecoveryDefinition = importService.definition("editor/Main.hx", aliasedRecoveryPosition),
			aliasedRecoveryReferences = importService.references("editor/Main.hx", aliasedRecoveryPosition);
		if (aliasedRecoveryDefinition == null
			|| aliasedRecoveryDefinition.path != "editor/util/Math.hx"
			|| aliasedRecoveryReferences.length != 2)
			throw "recovered aliased symbol resolution failed";
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
		var implementationCancellation = new CancellationToken(),
			implementationCancelled = false;
		implementationCancellation.cancel();
		try
			implementationService.implementations("api/Plugin.hx", contractSource.indexOf("Plugin") + 2, implementationCancellation)
		catch (_:compiler.service.CancellationError)
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
		var hierarchyTypeService = new LanguageService(),
			rootTypeSource = "package types; class Root {}",
			namedTypeSource = "package types; interface Named {}",
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
		if (rootSubtypes.length != 1 || rootSubtypes[0].name != "Branch" || branchSupertypes.length != 2 || branchSupertypes[0].name != "Named"
			|| branchSupertypes[1].name != "Root" || branchSubtypes.length != 1 || branchSubtypes[0].name != "Leaf" || namedSubtypes.length != 2
			|| namedSubtypes[0].name != "Branch" || namedSubtypes[1].name != "Detailed")
			throw "language service type hierarchy did not return direct class and interface relationships";
		hierarchyTypeService.update("types/Root.hx", rootTypeSource + " ");
		if (hierarchyTypeService.isTypeHierarchyCurrent(preparedRoot.identity, preparedRoot.revision))
			throw "language service accepted a stale type hierarchy item";
		var recoveredHierarchyService = new LanguageService(),
			recoveredHierarchySource = "class Root {} class Branch extends Root {} class Leaf extends Branch {} function add(value:Int):Int return value; function main():Int return add(1);";
		recoveredHierarchyService.update("RecoveredHierarchy.hx", recoveredHierarchySource);
		var recoveredRoot = recoveredHierarchyService.prepareTypeHierarchy("RecoveredHierarchy.hx", recoveredHierarchySource.indexOf("Root") + 1),
			recoveredBranch = recoveredHierarchyService.prepareTypeHierarchy("RecoveredHierarchy.hx", recoveredHierarchySource.indexOf("Branch") + 1),
			recoveredAdd = recoveredHierarchyService.prepareCallHierarchy("RecoveredHierarchy.hx", recoveredHierarchySource.indexOf("add") + 1),
			recoveredMain = recoveredHierarchyService.prepareCallHierarchy("RecoveredHierarchy.hx", recoveredHierarchySource.lastIndexOf("main") + 1);
		if (recoveredRoot == null || recoveredBranch == null || recoveredAdd == null || recoveredMain == null)
			throw "language service did not prepare hierarchy items from a current recovered model";
		var recoveredRootSubtypes = recoveredHierarchyService.typeSubtypes(recoveredRoot.identity, recoveredRoot.revision),
			recoveredBranchSupertypes = recoveredHierarchyService.typeSupertypes(recoveredBranch.identity, recoveredBranch.revision),
			recoveredIncoming = recoveredHierarchyService.incomingCalls(recoveredAdd.identity, recoveredAdd.revision),
			recoveredOutgoing = recoveredHierarchyService.outgoingCalls(recoveredMain.identity, recoveredMain.revision);
		if (recoveredRootSubtypes.length != 1
			|| recoveredRootSubtypes[0].name != "Branch"
			|| recoveredBranchSupertypes.length != 1
			|| recoveredBranchSupertypes[0].name != "Root"
			|| recoveredIncoming.length != 1
			|| recoveredIncoming[0].item.name != "main"
			|| recoveredOutgoing.length != 1
			|| recoveredOutgoing[0].item.name != "add")
			throw "language service hierarchy queries did not consume current recovered calls and types";
		var recoveredCrossModuleHierarchy = new LanguageService(),
			recoveredCrossModuleRoot = "package recovered.types; class Root {}",
			recoveredCrossModuleBranch = "package recovered; import recovered.types.Root; class Branch extends Root {}";
		recoveredCrossModuleHierarchy.update("recovered/types/Root.hx", recoveredCrossModuleRoot);
		recoveredCrossModuleHierarchy.update("recovered/Branch.hx", recoveredCrossModuleBranch);
		var recoveredCrossModuleBranchItem = recoveredCrossModuleHierarchy.prepareTypeHierarchy("recovered/Branch.hx",
			recoveredCrossModuleBranch.indexOf("Branch") + 2);
		if (recoveredCrossModuleBranchItem == null)
			throw "language service did not prepare a cross-module recovered type hierarchy item";
		var recoveredCrossModuleSupers = recoveredCrossModuleHierarchy.typeSupertypes(recoveredCrossModuleBranchItem.identity,
			recoveredCrossModuleBranchItem.revision);
		if (recoveredCrossModuleSupers.length != 1 || recoveredCrossModuleSupers[0].name != "Root")
			throw "language service did not resolve an imported recovered type hierarchy parent";
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
			|| bodyAnalysis.retyped.indexOf("main") >= 0)
			throw "semantic index refresh did not preserve declaration-level invalidation";
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
		if (structuralAnalysis.retyped.indexOf("main") >= 0
			|| structuralAnalysis.retyped.indexOf("shapeapp.Main.helper") < 0
			|| originalConsumerIndex == updatedConsumerIndex
			|| updatedConsumerIndex.symbolIdAt(choiceUse) == null)
			throw "public enum change did not selectively refresh dependent semantic indexes";
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
		if (!largeCompletionResult.isIncomplete
			|| firstLargeCompletion.length != 200
			|| secondLargeCompletion.length != firstLargeCompletion.length)
			throw 'completion result limit was not enforced: ${firstLargeCompletion.length}';
		for (index in 0...firstLargeCompletion.length)
			if (firstLargeCompletion[index].label != secondLargeCompletion[index].label)
				throw "bounded completion ordering was not deterministic";
		var largeIndex = largeService.compiler.modules.get("Large").semanticModel.index;
		if (largeIndex.indexingMs < 0)
			throw "semantic indexing timing was not recorded";
		var cancelled = new CancellationToken();
		cancelled.cancel();
		var completionCancelled = false,
			referencesCancelled = false,
			recoveredReferencesCancelled = false,
			symbolsCancelled = false,
			foldingCancelled = false,
			selectionCancelled = false,
			hoverCancelled = false,
			signatureCancelled = false,
			definitionCancelled = false,
			renameCancelled = false;
		try
			largeService.complete("Large.hx", largeText.length, cancelled)
		catch (_:compiler.service.CancellationError)
			completionCancelled = true;
		try
			service.references("Main.hx", methodPosition, cancelled)
		catch (_:compiler.service.CancellationError)
			referencesCancelled = true;
		var recoveredCancellationService = new LanguageService(),
			recoveredCancellationSource = "function main():Int { var value:Int = 1; value;";
		recoveredCancellationService.update("RecoveredCancellation.hx", recoveredCancellationSource);
		try
			recoveredCancellationService.references("RecoveredCancellation.hx", recoveredCancellationSource.lastIndexOf("value;") + 1, cancelled)
		catch (_:compiler.service.CancellationError)
			recoveredReferencesCancelled = true;
		try
			largeService.documentSymbols("Large.hx", cancelled)
		catch (_:compiler.service.CancellationError)
			symbolsCancelled = true;
		try
			largeService.foldingRanges("Large.hx", cancelled)
		catch (_:compiler.service.CancellationError)
			foldingCancelled = true;
		try
			largeService.selectionRanges("Large.hx", [largeText.length], cancelled)
		catch (_:compiler.service.CancellationError)
			selectionCancelled = true;
		try
			service.hover("Main.hx", hoverPosition, cancelled)
		catch (_:compiler.service.CancellationError)
			hoverCancelled = true;
		try
			service.signatureHelp("Main.hx", source.indexOf("Editor.make") + "Editor.make(".length, cancelled)
		catch (_:compiler.service.CancellationError)
			signatureCancelled = true;
		try
			service.definition("Main.hx", methodPosition, cancelled)
		catch (_:compiler.service.CancellationError)
			definitionCancelled = true;
		try
			service.rename("Main.hx", methodPosition, "show", cancelled)
		catch (_:compiler.service.CancellationError)
			renameCancelled = true;
		if (!completionCancelled || !referencesCancelled || !recoveredReferencesCancelled || !symbolsCancelled || !foldingCancelled || !selectionCancelled
			|| !hoverCancelled || !signatureCancelled || !definitionCancelled || !renameCancelled)
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
		var sameIdentityConfigService = new LanguageService(),
			sameIdentityConfigSource = "#if feature\nfunction featureOnly():Int return 1;\n#else\nfunction fallbackOnly():Int return 2;\n#end\nfunction main():Int return 0;";
		sameIdentityConfigService.update("SameIdentityConfig.hx", sameIdentityConfigSource);
		sameIdentityConfigService.configure("same-build", "same-scope", []);
		sameIdentityConfigService.analyze("SameIdentityConfig");
		if (!containsDocumentSymbol(sameIdentityConfigService.documentSymbols("SameIdentityConfig.hx"), "fallbackOnly"))
			throw "same-identity configuration did not establish its initial defines";
		sameIdentityConfigService.configure("same-build", "same-scope", ["feature"]);
		sameIdentityConfigService.analyze("SameIdentityConfig");
		if (!containsDocumentSymbol(sameIdentityConfigService.documentSymbols("SameIdentityConfig.hx"), "featureOnly"))
			throw "same-identity define changes did not invalidate conditional analysis";
		var immediateDefineService = new LanguageService();
		immediateDefineService.configure("editor-defines", "shared-scope", ["feature", "version=3.0"]);
		immediateDefineService.update("ImmediateConditional.hx",
			"#if feature && version >= 2.5\nfunction featureOnly():Int return 1;\n#else\nfunction fallbackOnly():Int return 2;\n#end\nfunction main():Int return 0;");
		var immediateState = immediateDefineService.compiler.modules.get("ImmediateConditional"),
			immediateSymbols = immediateDefineService.documentSymbols("ImmediateConditional.hx");
		if (immediateState.conditionalDefines.indexOf("feature") < 0
			|| immediateState.conditionalDefines.indexOf("version") < 0
			|| !containsDocumentSymbol(immediateSymbols, "featureOnly")
			|| containsDocumentSymbol(immediateSymbols, "fallbackOnly"))
			throw "immediate recovery did not honor valued conditional defines";
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
			staleReferences = service.references("Main.hx", methodPosition),
			staleRename = service.rename("Main.hx", methodPosition, "display");
		if (recoveredSymbols.length == 0 || recoveredCompletion.length == 0)
			throw "failed edit discarded the last good language-service snapshot";
		if (recoveredSymbols[0].stale || recoveredSymbols[0].revision != 2 || recoveredCompletion[0].stale)
			throw "recoverable edit did not identify current semantic query results";
		if (staleReferences.length != 0 || staleRename.length != 0)
			throw "reference or rename unexpectedly used a symbol from the previous source revision";
		var foldingService = new LanguageService(),
			foldingSource = "function main():Int { if (true) { return 1;",
			unclosedBrace = foldingSource.indexOf("{", foldingSource.indexOf("if")),
			unclosedFolds = foldingService.foldingRanges("Unclosed.hx");
		foldingService.update("Unclosed.hx", foldingSource);
		unclosedFolds = foldingService.foldingRanges("Unclosed.hx");
		var hasUnclosedFold = false;
		for (fold in unclosedFolds)
			if (fold.span.start == unclosedBrace && fold.span.end == foldingSource.length)
				hasUnclosedFold = true;
		if (!hasUnclosedFold)
			throw "unmatched recovered blocks did not produce an end-of-source fold";
		var recoveredTopLevelService = new LanguageService(),
			recoveredTopLevelSource = "function complete(value:Int):String return \"\"; function main():Void { compl";
		recoveredTopLevelService.update("RecoveredTopLevel.hx", recoveredTopLevelSource);
		var recoveredTopLevelCompletion = recoveredTopLevelService.complete("RecoveredTopLevel.hx", recoveredTopLevelSource.length),
			hasRecoveredTopLevelSignature = false;
		for (item in recoveredTopLevelCompletion)
			if (item.label == "complete"
				&& item.detail == "complete(value:Int):String"
				&& item.insertText == "complete(")
				hasRecoveredTopLevelSignature = true;
		if (!hasRecoveredTopLevelSignature)
			throw "recovered top-level completion lost signature metadata before analysis";
		var cacheOrderService = new LanguageService(),
			initialCacheSource = "package cache.app; import cache.types.Types; function main():Void { var value:Types = new Types(); value.";
		cacheOrderService.update("cache/types/Types.hx", "package cache.types; class Types { public var oldValue:Int; }");
		cacheOrderService.update("cache/app/Main.hx", initialCacheSource);
		cacheOrderService.complete("cache/app/Main.hx", initialCacheSource.length);
		var initialTypingModuleBuilds = cacheOrderService.recoveredTypingModuleBuilds,
			unchangedDependencySource = "package cache.app; import cache.types.Types; function main():Void { var value:Types = new Types(); value.n";
		cacheOrderService.update("cache/app/Main.hx", unchangedDependencySource);
		if (cacheOrderService.recoveredTypingModuleBuilds != initialTypingModuleBuilds)
			throw 'recovered typing rebuilt an unchanged dependency module: initial=$initialTypingModuleBuilds current=${cacheOrderService.recoveredTypingModuleBuilds}';
		cacheOrderService.update("cache/types/Types.hx", "package cache.types; class Types { public var newValue:Int; }");
		if (cacheOrderService.recoveredTypingModuleBuilds <= initialTypingModuleBuilds)
			throw "dependency revision did not invalidate cached recovered typing artifacts";
		var cacheOrderSource = "package cache.app; import cache.types.Types; function main():Void { var value:Types = new Types(); value.";
		cacheOrderService.update("cache/app/Main.hx", cacheOrderSource);
		var cacheOrderNames = [
			for (item in cacheOrderService.complete("cache/app/Main.hx", cacheOrderSource.length))
				item.label
		];
		if (cacheOrderNames.indexOf("newValue") < 0 || cacheOrderNames.indexOf("oldValue") >= 0)
			throw "immediate recovery used stale workspace resolution cache";
		var samePackageService = new LanguageService(),
			samePackageSource = "package same; function main():Void { var value:Types = new Types(); value.";
		samePackageService.update("same/Types.hx", "package same; class Types { public var current:Int; }");
		samePackageService.update("same/Main.hx", samePackageSource);
		var samePackageNames = [
			for (item in samePackageService.complete("same/Main.hx", samePackageSource.length))
				item.label
		];
		if (samePackageNames.indexOf("current") < 0)
			throw "same-package recovery did not resolve the current type shape";
		var editorContext = samePackageService.completionContext("same/Main.hx", samePackageSource.length);
		if (editorContext == null
			|| editorContext.recovered != true
			|| editorContext.stale
			|| editorContext.context.receiver == null
			|| editorContext.revision != samePackageService.compiler.modules.get("same.Main").revision)
			throw "completion context did not retain editor snapshot metadata or receiver type";
		var candidateService = new LanguageService();
		candidateService.update("candidate/a/Library.hx", "package candidate.a; function shared():Void return;");
		candidateService.update("candidate/b/Library.hx", "package candidate.b; function shared():Void return;");
		var candidateSource = "package candidate.app; import candidate.a.Library; import candidate.b.Library; function main():Void { shared; }";
		candidateService.update("candidate/Main.hx", candidateSource);
		var candidateUnresolved:Null<compiler.semantic.SemanticIndex.UnresolvedSymbol> = null;
		for (symbol in candidateService.unresolvedSymbols("candidate/Main.hx"))
			if (symbol.name == "shared")
				candidateUnresolved = symbol;
		if (candidateUnresolved == null || candidateUnresolved.candidates.length != 2)
			throw 'recovered unresolved symbol candidates were not retained: ${candidateUnresolved == null ? "null" : Std.string(candidateUnresolved.candidates.length)}';
		var uniqueCandidateService = new LanguageService();
		uniqueCandidateService.update("candidate/unique/Library.hx", "package candidate.unique; function unique():Int return 1; function main():Void return;");
		var uniqueCandidateSource = "package candidate.app; import candidate.unique.Library; function main():Void { unique; }";
		uniqueCandidateService.update("candidate/unique/Main.hx", uniqueCandidateSource);
		var uniqueCandidateCompletion = uniqueCandidateService.completeResult("candidate/unique/Main.hx", uniqueCandidateSource.indexOf("unique;") + "unique".length),
			uniqueCandidateItem:Null<compiler.service.LanguageService.CompletionItem> = null;
		for (item in uniqueCandidateCompletion.items)
			if (item.label == "unique")
				uniqueCandidateItem = item;
		if (uniqueCandidateItem == null
			|| !StringTools.startsWith(uniqueCandidateItem.sortText, "1_")
			|| uniqueCandidateItem.identity != null
			|| uniqueCandidateItem.importPath != null)
			throw "unique recovered candidate did not get recovery-aware completion priority without speculative identity";
		var unresolvedService = new LanguageService(),
			unresolvedSource = "function main():Void { unknownName; }";
		unresolvedService.update("Unresolved.hx", unresolvedSource);
		var unresolved = unresolvedService.unresolvedSymbols("Unresolved.hx"),
			foundUnresolved = false;
		for (symbol in unresolved)
			if (symbol.name == "unknownName")
				foundUnresolved = true;
		if (!foundUnresolved || unresolvedService.unresolvedSymbolAt("Unresolved.hx", unresolvedSource.indexOf("unknownName") + 1) == null)
			throw "recovered unresolved symbols were not exposed through the language service";
		var unresolvedTypeSource = "function main():Void { var value:MissingType; }";
		unresolvedService.update("UnresolvedType.hx", unresolvedTypeSource);
		var unresolvedTypes = unresolvedService.unresolvedSymbols("UnresolvedType.hx"),
			foundUnresolvedType = false;
		for (symbol in unresolvedTypes)
			if (symbol.name == "MissingType")
				foundUnresolvedType = true;
		if (!foundUnresolvedType
			|| unresolvedService.unresolvedSymbolAt("UnresolvedType.hx", unresolvedTypeSource.indexOf("MissingType") + 1) == null)
			throw "recovered unresolved type references were not exposed through the language service";
		var localRecoveredNavigationService = new LanguageService(),
			localRecoveredNavigationSource = "class LocalType { public var value:Int; } function main():Void { var broken = ; var item:LocalType; item.value; }";
		localRecoveredNavigationService.update("LocalRecovered.hx", localRecoveredNavigationSource);
		var localRecoveredTypePosition = localRecoveredNavigationSource.indexOf(":LocalType") + 2,
			localRecoveredTypeDefinition = localRecoveredNavigationService.definition("LocalRecovered.hx", localRecoveredTypePosition),
			localRecoveredTypeReferences = localRecoveredNavigationService.references("LocalRecovered.hx", localRecoveredTypePosition);
		if (localRecoveredTypeDefinition == null
			|| localRecoveredTypeDefinition.path != "LocalRecovered.hx"
			|| localRecoveredTypeReferences.length < 2)
			throw "recovered same-module type identity was lost around a malformed statement";
		var duplicateRecoveryService = new LanguageService();
		duplicateRecoveryService.update("DuplicateRecovered.hx",
			"function same():Void return; function same():Void return; function usable():Void return;");
		if (duplicateRecoveryService.compiler.modules.get("DuplicateRecovered").recoveredSemanticModel == null
			|| duplicateRecoveryService.diagnostics("DuplicateRecovered.hx").length == 0
			|| !containsDocumentSymbol(duplicateRecoveryService.documentSymbols("DuplicateRecovered.hx"), "usable"))
			throw "recovered duplicate declarations lost the editor snapshot or semantic diagnostic";
		var removalService = new LanguageService();
		removalService.update("removed/Helper.hx", "package removed; class Helper { public var obsolete:Int; } function main():Void return;");
		var removalSource = "package removed; import removed.Helper; function main():Void { var helper:Helper = new Helper(); helper.";
		removalService.update("removed/Main.hx", removalSource);
		if ([
			for (item in removalService.complete("removed/Main.hx", removalSource.length))
				item.label
		].indexOf("obsolete") < 0)
			throw "dependency removal setup did not expose the recovered member";
		removalService.analyze("removed.Helper");
		if (removalService.compiler.semanticWorkspace.resolveTypeSymbolId("removed.Helper") == null)
			throw "dependency removal setup did not publish the authoritative type";
		if (!removalService.remove("removed/Helper.hx")
			|| removalService.remove("removed/Helper.hx")
			|| removalService.workspaceSymbols("obsolete").length != 0
			|| removalService.compiler.semanticWorkspace.resolveTypeSymbolId("removed.Helper") != null)
			throw "language-service removal did not invalidate deleted dependency state";
		if ([for (item in removalService.complete("removed/Main.hx", removalSource.length)) item.label].indexOf("obsolete") >= 0)
			throw "language-service removal retained a deleted member in the consumer recovery snapshot";
		var removalChainService = new LanguageService(),
			removalChainSource = "package removed.chain; import removed.chain.Middle; function main():Void { var middle:Middle = new Middle(); middle.";
		removalChainService.update("removed/chain/Base.hx", "package removed.chain; class Base { public var obsolete:Int; }");
		removalChainService.update("removed/chain/Middle.hx", "package removed.chain; import removed.chain.Base; class Middle extends Base {}");
		removalChainService.update("removed/chain/Main.hx", removalChainSource);
		if ([for (item in removalChainService.complete("removed/chain/Main.hx", removalChainSource.length)) item.label].indexOf("obsolete") < 0)
			throw "recovery removal chain setup did not expose the inherited member";
		if (!removalChainService.remove("removed/chain/Base.hx")
			|| [for (item in removalChainService.complete("removed/chain/Main.hx", removalChainSource.length)) item.label].indexOf("obsolete") >= 0)
			throw "ordered recovery rebuild retained a deleted transitive member";
		var unrecoverableService = new LanguageService(),
			unrecoverableSource = "function target():Int return 1; function main():Int return target();";
		unrecoverableService.update("Unrecoverable.hx", unrecoverableSource);
		unrecoverableService.compile("Unrecoverable");
		unrecoverableService.update("Unrecoverable.hx", "function target():Int return \"");
		if (unrecoverableService.references("Unrecoverable.hx", unrecoverableSource.indexOf("target") + 1).length != 0)
			throw "references unexpectedly used a last-good snapshot after unrecoverable input";
		var staleState = unrecoverableService.compiler.modules.get("Unrecoverable"),
			staleSource = staleState.lastGoodSource,
			staleFolds = unrecoverableService.foldingRanges("Unrecoverable.hx"),
			staleSelections = unrecoverableService.selectionRanges("Unrecoverable.hx", [0]),
			staleTokens = unrecoverableService.semanticTokens("Unrecoverable.hx");
		if (unrecoverableService.editorSnapshotConfidence("Unrecoverable.hx") != EditorSnapshotConfidence.LastGood)
			throw "unrecoverable input did not select the last-good snapshot confidence";
		if (staleSource == null)
			throw "unrecoverable input discarded the last-good source snapshot";
		for (fold in staleFolds)
			if (fold.span.file != staleSource || fold.span.end > staleSource.bytes.length)
				throw "stale folding ranges were built against the current broken source";
		for (ranges in staleSelections)
			for (range in ranges)
				if (range.file != staleSource || range.end > staleSource.bytes.length)
					throw "stale selection ranges were built against the current broken source";
		for (semanticToken in staleTokens)
			if (semanticToken.span.file != staleSource || semanticToken.span.end > staleSource.bytes.length)
				throw "stale semantic tokens were built against the current broken source";
		var immediateService = new LanguageService();
		immediateService.update("Immediate.hx", "function unfinished(value:Int,");
		if (immediateService.compiler.modules.get("Immediate").recoveredAst == null
			|| immediateService.documentSymbols("Immediate.hx").length != 1)
			throw "editor update did not publish an immediate recovered snapshot";
		if (immediateService.editorSnapshotConfidence("Immediate.hx") != EditorSnapshotConfidence.RecoveredPartial)
			throw "recovered input did not select partial snapshot confidence";
		var immediateIdentityPosition = "function unfinished(value:Int,".indexOf("unfinished") + 1,
			immediateIdentityContext = immediateService.completionContext("Immediate.hx", immediateIdentityPosition);
		if (immediateIdentityContext == null
			|| immediateIdentityContext.confidence != EditorSnapshotConfidence.RecoveredPartial
			|| !immediateIdentityContext.identityTrusted)
			throw "new recovered source identity was incorrectly promoted to authoritative confidence";
		var immediateRecoveryBuilds = immediateService.recoveredSnapshotBuilds;
		immediateService.update("Immediate.hx", "function unfinished(value:Int,");
		if (immediateService.recoveredSnapshotBuilds != immediateRecoveryBuilds)
			throw "duplicate editor updates rebuilt an unchanged recovery snapshot";
		try
			immediateService.analyze("Immediate")
		catch (_:CompileError) {}
		if (immediateService.recoveredSnapshotBuilds != immediateRecoveryBuilds)
			throw "background analysis rebuilt an unchanged recovery snapshot";
		if (immediateService.compiler.semanticWorkspace.resolveSymbolId("unfinished") != null)
			throw "recovered declaration contaminated the authoritative semantic workspace";
		var partialService = new LanguageService();
		partialService.update("Partial.hx", "function broken(:Int {} function alsoBroken(:Int {} function visible():Int return 42;");
		try {
			partialService.analyze("Partial");
			throw "invalid partial source unexpectedly analyzed";
		} catch (_:CompileError) {}
		var partialSymbols = partialService.documentSymbols("Partial.hx"),
			foundVisible = false;
		for (symbol in partialSymbols)
			if (symbol.name == "visible" && !symbol.stale)
				foundVisible = true;
		if (!foundVisible)
			throw "parser recovery did not preserve a valid declaration after malformed declarations";
		if (partialService.diagnostics("Partial.hx").length != 2)
			throw 'parser recovery did not collect multiple declaration diagnostics: ${[for (diagnostic in partialService.diagnostics("Partial.hx")) diagnostic.message].join(" | ")}';
		var delimiterService = new LanguageService();
		delimiterService.update("Delimiter.hx", "function first():Int return 1 function second():Int return 2;");
		try {
			delimiterService.analyze("Delimiter");
			throw "missing delimiter unexpectedly analyzed";
		} catch (_:CompileError) {}
		var delimiterSymbols = delimiterService.documentSymbols("Delimiter.hx"),
			delimiterDiagnostics = delimiterService.diagnostics("Delimiter.hx");
		if (delimiterSymbols.length != 2 || delimiterSymbols[0].name != "first" || delimiterSymbols[1].name != "second")
			throw "missing semicolon recovery did not retain adjacent declarations";
		if (delimiterDiagnostics.length != 1
			|| delimiterDiagnostics[0].fixes.length != 1
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
		var memberSymbols = memberService.documentSymbols("Members.hx"),
			foundMethod = false;
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
		var expressionSymbols = expressionService.documentSymbols("Expression.hx"),
			expressionCompletion = expressionService.complete("Expression.hx", expressionSource.length),
			completionNames = [for (item in expressionCompletion) item.label];
		if (expressionSymbols.length != 1 || expressionSymbols[0].name != "pending")
			throw "incomplete expression discarded its enclosing declaration";
		if (completionNames.indexOf("argument") < 0 || completionNames.indexOf("available") < 0)
			throw "recovered expression completion omitted current arguments or locals";
		var contextualRecoveryService = new LanguageService(),
			contextualRecoverySource = "class ExpectedValue { public var member:Int; } function take(value:ExpectedValue):Void return; function produce():ExpectedValue { return ",
			contextualRecoveryPosition = contextualRecoverySource.length;
		contextualRecoveryService.update("ContextualRecovery.hx", contextualRecoverySource);
		var returnContext = contextualRecoveryService.completionContext("ContextualRecovery.hx", contextualRecoveryPosition);
		if (returnContext == null || returnContext.context.expected == null
			|| Std.string(returnContext.context.expected).indexOf("ExpectedValue") < 0)
			throw "recovered return expression did not preserve the declared expected type";
		var callRecoverySource = "class ExpectedArgument { public var member:Int; } function take(value:ExpectedArgument):Void return; function main():Void { take(";
		contextualRecoveryService.update("ContextualRecovery.hx", callRecoverySource);
		var callContext = contextualRecoveryService.completionContext("ContextualRecovery.hx", callRecoverySource.length);
		if (callContext == null || callContext.context.expected == null
			|| Std.string(callContext.context.expected).indexOf("ExpectedArgument") < 0)
			throw "recovered call argument did not preserve the expected parameter type";
		var localAfterErrorSource = "class RecoveredValue { public var member:Int; } function main():Void { var value:RecoveredValue = new RecoveredValue(); broken.unresolved().thing; value.";
		contextualRecoveryService.update("ContextualRecovery.hx", localAfterErrorSource);
		var localAfterErrorPosition = localAfterErrorSource.length,
			localAfterErrorCompletion = contextualRecoveryService.completeResult("ContextualRecovery.hx", localAfterErrorPosition),
			foundRecoveredMember = false;
		for (item in localAfterErrorCompletion.items)
			if (item.label == "member")
				foundRecoveredMember = true;
		if (!foundRecoveredMember)
			throw "recovered local type was lost after an unrelated malformed expression";
		var visibilityService = new LanguageService();
		visibilityService.update("unrelated/Target.hx", "package unrelated; function target():Int return 1; function main():Void return;");
		visibilityService.analyze("unrelated.Target");
		var visibilitySource = "package visible; function main():Void { target(); }";
		visibilityService.update("visible/Main.hx", visibilitySource);
		var visibilityPosition = visibilitySource.indexOf("target") + 1,
			visibilityDefinition = visibilityService.definition("visible/Main.hx", visibilityPosition),
			visibilityReferences = visibilityService.references("visible/Main.hx", visibilityPosition);
		if (visibilityDefinition != null || visibilityReferences.length != 0)
			throw "recovered resolution bound a symbol from an invisible module";
		var invisibleTypeSource = "package visible; function main():Void { var value:Target; }";
		visibilityService.update("visible/TypeUse.hx", invisibleTypeSource);
		var invisibleTypePosition = invisibleTypeSource.indexOf("Target") + 1,
			invisibleTypeDefinition = visibilityService.typeDefinition("visible/TypeUse.hx", invisibleTypePosition);
		if (invisibleTypeDefinition != null)
			throw "recovered type resolution bound a type from an invisible module";
		visibilityService.update("other/Target.hx", "package other; function target():Int return 2; function main():Void return;");
		visibilityService.analyze("other.Target");
		var importedVisibilitySource = "package visible; import unrelated.Target; function main():Void { target(); }";
		visibilityService.update("visible/ImportedUse.hx", importedVisibilitySource);
		var importedVisibilityPosition = importedVisibilitySource.indexOf("target") + 1,
			importedVisibilityDefinition = visibilityService.definition("visible/ImportedUse.hx", importedVisibilityPosition);
		if (importedVisibilityDefinition == null || importedVisibilityDefinition.path != "unrelated/Target.hx")
			throw "recovered resolution discarded the uniquely imported symbol among duplicate names";
		var nominalVisibilityService = new LanguageService();
		nominalVisibilityService.update("nominal/a/Foo.hx", "package nominal.a; class Foo { public var fromA:Int; }");
		nominalVisibilityService.update("nominal/b/Foo.hx", "package nominal.b; class Foo { public var fromB:Int; }");
		var nominalVisibilitySource = "package nominal.app; import nominal.b.Foo; function main():Void { var value:Foo = new Foo(); value.";
		nominalVisibilityService.update("nominal/app/Main.hx", nominalVisibilitySource);
		var nominalVisibilityItems = nominalVisibilityService.completeResult("nominal/app/Main.hx", nominalVisibilitySource.length).items,
			foundImportedMember = false,
			foundInvisibleMember = false;
		for (item in nominalVisibilityItems) {
			if (item.label == "fromB")
				foundImportedMember = true;
			if (item.label == "fromA")
				foundInvisibleMember = true;
		}
		if (!foundImportedMember || foundInvisibleMember)
			throw "recovered nominal typing lost the imported type identity during member completion";
		var nominalHoverService = new LanguageService();
		nominalHoverService.update("nominal/a/Value.hx", "package nominal.a; class Value { public var shared:Int; }");
		nominalHoverService.update("nominal/b/Value.hx", "package nominal.b; class Value { public var shared:String; }");
		var nominalHoverSource = "package nominal.app; import nominal.b.Value; function main():Void { var value:Value = new Value(); value.shared; }";
		nominalHoverService.update("nominal/app/Hover.hx", nominalHoverSource);
		var nominalHoverPosition = nominalHoverSource.lastIndexOf("shared") + "shared".length;
		if (nominalHoverService.hover("nominal/app/Hover.hx", nominalHoverPosition) != "shared:String")
			throw "recovered nominal typing lost the imported type identity during hover";
		var nominalStaticService = new LanguageService();
		nominalStaticService.update("nominal/a/StaticValue.hx", "package nominal.a; class StaticValue { public static var shared:Int; }");
		nominalStaticService.update("nominal/b/StaticValue.hx", "package nominal.b; class StaticValue { public static var shared:String; } function main():Void return;");
		nominalStaticService.analyze("nominal.b.StaticValue");
		var nominalStaticSource = "package nominal.app; import nominal.b.StaticValue; function main():Void { StaticValue.shared; }";
		nominalStaticService.update("nominal/app/StaticUse.hx", nominalStaticSource);
		var nominalStaticPosition = nominalStaticSource.lastIndexOf("shared") + "shared".length;
		var nominalStaticHover = nominalStaticService.hover("nominal/app/StaticUse.hx", nominalStaticPosition);
		if (nominalStaticHover != "shared:String")
			throw 'recovered nominal typing lost the imported type identity during static-member hover: ${nominalStaticHover == null ? "null" : nominalStaticHover}';
		var nominalSignatureService = new LanguageService();
		nominalSignatureService.update("nominal/a/Action.hx", "package nominal.a; class Action { public function run(value:Int):Int return value; }");
		nominalSignatureService.update("nominal/b/Action.hx", "package nominal.b; class Action { public function run(value:String):String return value; }");
		var nominalSignatureSource = "package nominal.app; import nominal.b.Action; function main():Void { var action:Action = new Action(); action.run(";
		nominalSignatureService.update("nominal/app/Signature.hx", nominalSignatureSource);
		var nominalSignature = nominalSignatureService.signatureHelp("nominal/app/Signature.hx", nominalSignatureSource.length);
		if (nominalSignature == null || nominalSignature.label != "run(value:String):String")
			throw 'recovered nominal typing lost the imported type identity during signature help: ${nominalSignature == null ? "null" : nominalSignature.label}';
		var scopedEnumService = new LanguageService();
		scopedEnumService.update("nominal/other/Kind.hx", "package nominal.other; enum Kind { Value; }");
		scopedEnumService.update("nominal/app/Kind.hx", "package nominal.app; enum Kind { Value; } function main():Void return;");
		scopedEnumService.analyze("nominal.app.Kind");
		var scopedEnumSource = "package nominal.app; function main():Void { Kind.Value; }";
		scopedEnumService.update("nominal/app/EnumUse.hx", scopedEnumSource);
		var scopedEnumPosition = scopedEnumSource.indexOf("Value") + 1,
			scopedEnumDefinition = scopedEnumService.definition("nominal/app/EnumUse.hx", scopedEnumPosition);
		if (scopedEnumDefinition == null || scopedEnumDefinition.path != "nominal/app/Kind.hx")
			throw "recovered enum-case resolution did not prefer the visible same-package enum";
		var transitionService = new LanguageService(),
			validEditorSource = "class Foo { public var knownFoo:Int; } function main():Int { var foo:Foo = new Foo(); return foo.knownFoo; }";
		transitionService.update("Transition.hx", validEditorSource);
		transitionService.analyze("Transition");
		var validPosition = validEditorSource.indexOf("foo.knownFoo") + "foo.".length,
			validReceiverPosition = validEditorSource.indexOf("foo.knownFoo") + 1,
			validId = transitionService.compiler.modules.get("Transition").semanticModel.index.symbolIdAt(validReceiverPosition);
		if (validId == null || transitionService.completeResult("Transition.hx", validPosition).isIncomplete)
			throw "valid editor snapshot was not complete before a recovery transition";
		if (transitionService.editorSnapshotConfidence("Transition.hx") != EditorSnapshotConfidence.Exact)
			throw "valid input did not select exact snapshot confidence";
		var incompleteEditorSource = "class Foo { public var knownFoo:Int; } function main():Int { var foo:Foo = new Foo(); return foo. }";
		transitionService.update("Transition.hx", incompleteEditorSource);
		var recoveredPosition = incompleteEditorSource.indexOf("foo.") + "foo.".length,
			recoveredResult = transitionService.completeResult("Transition.hx", recoveredPosition),
			recoveredId = transitionService.compiler.modules.get("Transition")
				.recoveredSemanticModel.index.symbolIdAt(incompleteEditorSource.indexOf("foo.") + 1);
		if (!recoveredResult.isIncomplete || recoveredId == null || Std.string(recoveredId) != Std.string(validId))
			throw 'recovery transition did not preserve the local semantic identity: valid=${Std.string(validId)} recovered=${Std.string(recoveredId)}';
		if (transitionService.editorSnapshotConfidence("Transition.hx") != EditorSnapshotConfidence.RecoveredPartial)
			throw "recovery transition did not select partial snapshot confidence";
		transitionService.update("Transition.hx", validEditorSource);
		transitionService.analyze("Transition");
		var restored = transitionService.completeResult("Transition.hx", validPosition),
			restoredId = transitionService.compiler.modules.get("Transition").semanticModel.index.symbolIdAt(validReceiverPosition);
		if (restored.isIncomplete || restoredId == null || Std.string(restoredId) != Std.string(validId))
			throw "valid editor snapshot did not replace recovery with the original semantic identity";
		var stableIdentityService = new LanguageService(),
			stableIdentitySource = "class StableType { public var member:Int; } function main():Void { var first:Int = 1; var target:StableType = new StableType(); target.member; }";
		stableIdentityService.update("StableIdentity.hx", stableIdentitySource);
		stableIdentityService.analyze("StableIdentity");
		var stableIdentityUse = stableIdentitySource.lastIndexOf("target.member"),
			stableIdentity = stableIdentityService.compiler.modules.get("StableIdentity").semanticModel.index.symbolIdAt(stableIdentityUse + 1);
		if (stableIdentity == null)
			throw "baseline local identity was not indexed";
		var insertedIdentitySource = "class StableType { public var member:Int; } function main():Void { var inserted:Int = 0; var first:Int = 1; var target:StableType = new StableType(); target.";
		stableIdentityService.update("StableIdentity.hx", insertedIdentitySource);
		var insertedIdentityUse = insertedIdentitySource.lastIndexOf("target."),
			recoveredIdentity = stableIdentityService.compiler.modules.get("StableIdentity").recoveredSemanticModel.index.symbolIdAt(insertedIdentityUse + 1);
		if (recoveredIdentity == null || Std.string(recoveredIdentity) != Std.string(stableIdentity))
			throw 'recovery renumbered an unaffected local identity: baseline=${Std.string(stableIdentity)} recovered=${Std.string(recoveredIdentity)}';
		var introducedIdentitySource = "class StableType { public var member:Int; } function main():Void { var introduced:Int = 0; var target:StableType = new StableType(); target.";
		stableIdentityService.update("StableIdentity.hx", introducedIdentitySource);
		var introducedIdentityPosition = introducedIdentitySource.indexOf("introduced"),
			introducedIdentity = stableIdentityService.compiler.modules.get("StableIdentity").recoveredSemanticModel.index.symbolIdAt(introducedIdentityPosition + 1);
		if (introducedIdentity == null)
			throw "new recovered local identity was not indexed";
		var secondRecoverySource = "class StableType { public var member:Int; } function main():Void { var another:Int = 0; var introduced:Int = 0; var target:StableType = new StableType(); target.";
		stableIdentityService.update("StableIdentity.hx", secondRecoverySource);
		var secondIntroducedPosition = secondRecoverySource.indexOf("introduced"),
			secondIntroducedIdentity = stableIdentityService.compiler.modules.get("StableIdentity").recoveredSemanticModel.index.symbolIdAt(secondIntroducedPosition + 1);
		if (secondIntroducedIdentity == null || Std.string(secondIntroducedIdentity) != Std.string(introducedIdentity))
			throw 'consecutive recovery edits churned a recovered local identity: first=${Std.string(introducedIdentity)} second=${Std.string(secondIntroducedIdentity)}';
		var lambdaIdentityService = new LanguageService(),
			lambdaIdentitySource = "class StableLambdaType { public var member:Int; } function main():Void { var callback = (value:StableLambdaType) -> { var item:StableLambdaType = value; item.member; }; }";
		lambdaIdentityService.update("StableLambda.hx", lambdaIdentitySource);
		lambdaIdentityService.analyze("StableLambda");
		var lambdaUse = lambdaIdentitySource.indexOf("item.member"),
			lambdaIdentity = lambdaIdentityService.compiler.modules.get("StableLambda").semanticModel.index.symbolIdAt(lambdaUse + 1);
		if (lambdaIdentity == null)
			throw "baseline lambda local identity was not indexed";
		var recoveredLambdaSource = "class StableLambdaType { public var member:Int; } function main():Void { var inserted:Int = 0; var callback = (value:StableLambdaType) -> { var item:StableLambdaType = value; item.; }";
		lambdaIdentityService.update("StableLambda.hx", recoveredLambdaSource);
		var recoveredLambdaUse = recoveredLambdaSource.indexOf("item."),
			recoveredLambdaIdentity = lambdaIdentityService.compiler.modules.get("StableLambda")
				.recoveredSemanticModel.index.symbolIdAt(recoveredLambdaUse + 1);
		if (recoveredLambdaIdentity == null || Std.string(recoveredLambdaIdentity) != Std.string(lambdaIdentity))
			throw 'recovery churned an unaffected lambda local identity: baseline=${Std.string(lambdaIdentity)} recovered=${Std.string(recoveredLambdaIdentity)}';
		var noSnapshotCompletionService = new LanguageService();
		noSnapshotCompletionService.update("NoSnapshotCompletion.hx", "function main():Void return \"");
		if (!noSnapshotCompletionService.completeResult("NoSnapshotCompletion.hx", 0).isIncomplete)
			throw "completion did not request a retry when no editor snapshot was available";
		var incrementalRecoveryService = new LanguageService(),
			incrementalSource = "function stable():Int { var value:Int = 1; return value; } function edited():Int { return 1; }";
		incrementalRecoveryService.update("IncrementalRecovery.hx", incrementalSource);
		var initialReuseCount = incrementalRecoveryService.recoveredTypedFunctionReuses;
		if (initialReuseCount != 0)
			throw "first recovered snapshot unexpectedly reused a typed function";
		var changedIncrementalSource = "function stable():Int { var value:Int = 1; return value; } function edited():Int { return 2; }";
		incrementalRecoveryService.update("IncrementalRecovery.hx", changedIncrementalSource);
		if (incrementalRecoveryService.recoveredTypedFunctionReuses != initialReuseCount + 1)
			throw 'recovered typing did not reuse the unchanged declaration: ${incrementalRecoveryService.recoveredTypedFunctionReuses}';
		var incrementalModel = incrementalRecoveryService.compiler.modules.get("IncrementalRecovery").recoveredSemanticModel,
			editedLiteral:Null<Int> = null;
		if (incrementalModel != null && incrementalModel.partialTypedProgram != null)
			for (fn in incrementalModel.partialTypedProgram.functions)
				if (fn.name == "edited")
					for (statement in fn.statements)
						switch statement {
							case TReturn(expression, _):
								switch expression.expression {
									case TIntLiteral(value):
										editedLiteral = value;
									default:
								}
							default:
						}
		if (editedLiteral != 2)
			throw 'recovered typing reused a changed body: ${editedLiteral}';
		var classIncrementalService = new LanguageService(),
			classIncrementalSource = "class Incremental { public function stable():Int { return 1; } public function edited():Int { return 1; } }";
		classIncrementalService.update("ClassIncremental.hx", classIncrementalSource);
		var classInitialReuseCount = classIncrementalService.recoveredTypedFunctionReuses;
		classIncrementalService.update("ClassIncremental.hx",
			"class Incremental { public function stable():Int { return 1; } public function edited():Int { return 2; } }");
		if (classIncrementalService.recoveredTypedFunctionReuses != classInitialReuseCount + 1)
			throw "recovered typing did not reuse an unchanged class method";
		var abstractIncrementalService = new LanguageService(),
			abstractIncrementalSource = "abstract IncrementalValue(Int) { public static function stable():Int return 1; public static function edited():Int return 1; }";
		abstractIncrementalService.update("AbstractIncremental.hx", abstractIncrementalSource);
		var abstractInitialReuseCount = abstractIncrementalService.recoveredTypedFunctionReuses;
		abstractIncrementalService.update("AbstractIncremental.hx",
			"abstract IncrementalValue(Int) { public static function stable():Int return 1; public static function edited():Int return 2; }");
		if (abstractIncrementalService.recoveredTypedFunctionReuses != abstractInitialReuseCount + 1)
			throw "recovered typing did not reuse an unchanged abstract static method";
		var dependentIncrementalService = new LanguageService(),
			dependentIncrementalSource = "function stable():Void { changed(); return; } function changed():Void { throw  1; }";
		dependentIncrementalService.update("DependentIncremental.hx", dependentIncrementalSource);
		dependentIncrementalService.update("DependentIncremental.hx",
			"function stable():Void { changed(); return; } function changed():Void { return ; }");
		var dependentModel = dependentIncrementalService.compiler.modules.get("DependentIncremental").recoveredSemanticModel,
			stableNoReturn = false;
		if (dependentModel != null && dependentModel.partialTypedProgram != null)
			for (fn in dependentModel.partialTypedProgram.functions)
				if (fn.name == "stable")
					for (statement in fn.statements)
						switch statement {
							case TExpression(expression, _):
								switch expression.expression {
									case TNoReturn(_): stableNoReturn = true;
									default:
								}
							default:
						}
		if (stableNoReturn)
			throw "recovered typing reused stale no-return semantics from a changed dependency";
		if (dependentIncrementalService.recoveredTypedFunctionReuses != 0)
			throw "recovered typing reused a body whose callee changed";
		var externalDependencyService = new LanguageService(),
			externalDependencySource = "package external; function changed():Void { throw  1; }",
			externalConsumerSource = "package external.app; import external.Dependency; function stable():Void { changed(); return; } function independent():Int return 1;";
		externalDependencyService.update("external/Dependency.hx", externalDependencySource);
		externalDependencyService.update("external/Consumer.hx", externalConsumerSource);
		var externalReuseBefore = externalDependencyService.recoveredTypedFunctionReuses;
		var initialExternalModel = externalDependencyService.compiler.modules.get("external.Consumer").recoveredSemanticModel,
			initialExternalNoReturn = false;
		if (initialExternalModel != null && initialExternalModel.partialTypedProgram != null)
			for (fn in initialExternalModel.partialTypedProgram.functions)
				if (fn.name == "stable")
					for (statement in fn.statements)
						switch statement {
							case TExpression(expression, _):
								switch expression.expression {
								case TNoReturn(_): initialExternalNoReturn = true;
								default:
							}
							default:
						}
		if (!initialExternalNoReturn)
			throw "recovered typing did not resolve the initial imported callee control flow";
		externalDependencyService.update("external/Dependency.hx", "package external; function changed():Void { return ; }");
		var externalModel = externalDependencyService.compiler.modules.get("external.Consumer").recoveredSemanticModel,
			staleExternalNoReturn = false;
		if (externalModel != null && externalModel.partialTypedProgram != null)
			for (fn in externalModel.partialTypedProgram.functions)
				if (fn.name == "stable")
					for (statement in fn.statements)
						switch statement {
							case TExpression(expression, _):
								switch expression.expression {
								case TNoReturn(_): staleExternalNoReturn = true;
								default:
							}
							default:
						}
		if (staleExternalNoReturn)
			throw "recovered typing reused a body after an imported callee changed";
		if (externalDependencyService.recoveredTypedFunctionReuses <= externalReuseBefore)
			throw 'cross-module recovery regression did not exercise recovered body reuse: before=$externalReuseBefore after=${externalDependencyService.recoveredTypedFunctionReuses}';
		var contextRecoveryService = new LanguageService(),
			contextSource = "function stable():Int { return 1; } class Context { public static var value:Int = 1; }";
		contextRecoveryService.update("ContextRecovery.hx", contextSource);
		var contextReuseCount = contextRecoveryService.recoveredTypedFunctionReuses;
		contextRecoveryService.update("ContextRecovery.hx", "function stable():Int { return 1; } class Context { public static var value:Int = 2; }");
		if (contextRecoveryService.recoveredTypedFunctionReuses != contextReuseCount)
			throw "recovered typing reused a body after its declaration context changed";
		Sys.println("PASS: compiler-backed language service snapshot works");
	}

	static function containsDocumentSymbol(symbols:Array<DocumentSymbol>, name:String):Bool {
		for (symbol in symbols)
			if (symbol.name == name)
				return true;
		return false;
	}
}
