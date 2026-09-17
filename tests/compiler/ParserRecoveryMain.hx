import compiler.service.LanguageService;
import compiler.Compiler;
import compiler.service.CancellationError;
import compiler.service.CancellationToken;
import compiler.service.RecoveryEngine;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticModel;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.DiagnosticOrigin;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.semantic.SemanticIndex.SemanticCompletionContextKind;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

class ParserRecoveryMain {
	static function main():Void {
		var service = new LanguageService(),
			source = "class Box { public var value:Int; public function read():Int return value; } function main():Int { var box:Box = new Box(); box.value; box.";
		service.update("Main.hx", source);
		try
			service.analyze("Main")
		catch (_:CompileError) {}
		var completionResult = service.completeResult("Main.hx", source.length),
			completion = completionResult.items,
			names = [for (item in completion) item.label];
		if (!completionResult.isIncomplete)
			throw "recovered completion did not request a follow-up query";
		if (names.indexOf("value") < 0 || names.indexOf("read") < 0)
			throw "incomplete member access did not retain recovered receiver completion";
		for (item in completion)
			if ((item.label == "value" || item.label == "read") && item.stale)
				throw "recovered current completion was incorrectly marked stale";
		var boxDeclaration = source.indexOf("box:Box");
		if (service.hover("Main.hx", boxDeclaration + 1) != "box:Box")
			throw "recovered semantic model did not expose the current local type";
		var boxUse = source.lastIndexOf("box.");
		var definition = service.definition("Main.hx", boxUse + 1),
			references = service.references("Main.hx", boxUse + 1),
			rename = service.rename("Main.hx", boxUse + 1, "renamed"),
			highlights = service.documentHighlights("Main.hx", boxUse + 1);
		if (definition == null || definition.span.start != boxDeclaration || definition.stale)
			throw 'recovered local definition did not resolve to the current declaration: ${definition == null ? "null" : definition.span.start + ":" + definition.stale} expected $boxDeclaration';
		if (references.length < 2 || rename.length != 0 || highlights.length != references.length)
			throw "recovered local references, rename, or highlights were incomplete";
		var valueUse = source.lastIndexOf("value;"),
			valueDeclaration = source.indexOf("value:Int"),
			memberDefinition = service.definition("Main.hx", valueUse + 1);
		if (memberDefinition == null
			|| valueDeclaration < memberDefinition.span.start
			|| valueDeclaration > memberDefinition.span.end
			|| memberDefinition.stale)
			throw "recovered member definition did not resolve to the current field";

		var typeService = new LanguageService(),
			typeSource = "class Foo {} function main():Int { var unfinished:";
		typeService.update("Type.hx", typeSource);
		try
			typeService.analyze("Type")
		catch (_:CompileError) {}
		var typeModel = typeService.compiler.modules.get("Type").recoveredSemanticModel,
			locals = [for (item in typeService.complete("Type.hx", typeSource.length)) item.label];
		if (typeModel == null || typeModel.index.completionContext(typeSource.length).kind != SemanticCompletionContextKind.Type)
			throw "unfinished type annotation did not expose a type completion context";
		if (locals.indexOf("Foo") < 0 || locals.indexOf("unfinished") >= 0)
			throw "type completion mixed value locals into an incomplete type annotation";
		var genericTypeService = new LanguageService(),
			genericTypeSource = "class Foo {} function main():Void { var values:Array<Foo> = []; var item:Array<Fo";
		genericTypeService.update("GenericType.hx", genericTypeSource);
		var genericTypeModel = genericTypeService.compiler.modules.get("GenericType").recoveredSemanticModel,
			genericTypeContext = genericTypeModel == null ? null : genericTypeModel.index.completionContext(genericTypeSource.length),
			genericTypeNames = [for (item in genericTypeService.complete("GenericType.hx", genericTypeSource.length)) item.label];
		if (genericTypeContext == null || genericTypeContext.kind != SemanticCompletionContextKind.Type || genericTypeNames.indexOf("Foo") < 0)
			throw "unfinished generic type argument did not expose type completion";
		var nestedGenericTypeService = new LanguageService(),
			nestedGenericTypeSource = "class Foo {} function main():Void { var item:Map<String, Fo";
		nestedGenericTypeService.update("NestedGenericType.hx", nestedGenericTypeSource);
		var nestedGenericTypeModel = nestedGenericTypeService.compiler.modules.get("NestedGenericType").recoveredSemanticModel,
			nestedGenericTypeContext = nestedGenericTypeModel == null ? null : nestedGenericTypeModel.index.completionContext(nestedGenericTypeSource.length);
		if (nestedGenericTypeContext == null || nestedGenericTypeContext.kind != SemanticCompletionContextKind.Type)
			throw "unfinished nested generic type argument was not classified as a type context";
		var expressionContextService = new LanguageService(),
			expressionContextSource = "function main():Void { true ? false : value; }";
		expressionContextService.update("ExpressionContext.hx", expressionContextSource);
		var expressionContextModel = expressionContextService.compiler.modules.get("ExpressionContext").recoveredSemanticModel,
			expressionContext = expressionContextModel == null ? null : expressionContextModel.index.completionContext(expressionContextSource.length);
		if (expressionContext == null || expressionContext.kind != SemanticCompletionContextKind.Expression)
			throw "ternary expression was incorrectly classified as a type context";

		for (tail in ["consume(", "values[", "true ?", "if (", "switch (", "(item:Int) ->"])
			assertNestedRecovery(tail);
		assertIncompleteDeclarations();
		assertPartialTypeFacts();
		assertTolerantTypedSnapshot();
		assertTolerantDeclarationSnapshot();
		assertRecoveryCancellation();
		assertSupersededRecovery();
		assertTransactionSourceGeneration();
		assertDiagnosticOrigins();
		assertTruncationRecovery();
		assertTolerantTruncationTyping();
		assertRecoveredTypeNavigation();
		assertQualifiedIdentityClosure();
		assertGenericExternalEnumDetails();
		assertPackageVisibilityClosure();
		assertRecoveredAuxiliaryExpressions();
		Sys.println("PASS: incomplete member and type recovery support completion");
	}

	static function assertRecoveredAuxiliaryExpressions():Void {
		var service = new LanguageService(),
			source = "class Provider { public static function make():Int return 1; } class Main { public static var value:Int = Provider.make(); public function unfinished(";
		service.update("AuxiliaryRecovery.hx", source);
		var use = source.indexOf("Provider.make") + "Provider.".length,
			definition = service.definition("AuxiliaryRecovery.hx", use),
			references = service.references("AuxiliaryRecovery.hx", use);
		if (definition == null || definition.stale || definition.span.start != source.indexOf("function make"))
			throw 'recovered field initializer did not retain its method definition: ${definition == null ? "null" : definition.path + ":" + definition.span.start + ":" + definition.stale} expected ${source.indexOf("function make")}';
		var currentUse = false;
		for (reference in references)
			if (reference.path == "AuxiliaryRecovery.hx" && !reference.stale
				&& reference.span.start == use)
				currentUse = true;
		if (!currentUse)
			throw "recovered field initializer did not retain its method reference";

		var defaultSource = "class Provider { public static function make():Int return 1; } function use(value:Provider = Provider.make()):Void return;";
		service.update("AuxiliaryRecovery.hx", defaultSource);
		var defaultPosition = defaultSource.indexOf("Provider.make") + "Provider.".length,
			defaultDefinition = service.definition("AuxiliaryRecovery.hx", defaultPosition);
		if (defaultDefinition == null || defaultDefinition.stale || defaultDefinition.span.start != defaultSource.indexOf("function make"))
			throw "recovered parameter default did not retain its method definition";
	}

	static function assertRecoveredTypeNavigation():Void {
		var service = new LanguageService(),
			targetSource = "package types; class Foo {} function main():Void return;";
		service.update("types/Foo.hx", targetSource);
		service.analyze("types.Foo");
		var source = "package use; import types.Foo; function main(value:Foo):Foo { return value;";
		service.update("use/Main.hx", source);
		var position = source.indexOf(":Foo") + 1,
			definition = service.definition("use/Main.hx", position),
			references = service.references("use/Main.hx", position),
			currentReferences = 0;
		for (reference in references)
			if (reference.path == "use/Main.hx" && !reference.stale)
				currentReferences++;
		if (definition == null
			|| definition.path != "types/Foo.hx"
			|| currentReferences < 3)
			throw 'recovered type navigation did not bind the authoritative identity: definition=${definition == null ? "null" : definition.path}, references=${references.length}, current=${currentReferences}';
	}

	static function assertQualifiedIdentityClosure():Void {
		var service = new LanguageService(),
			targetSource = "package identity.lib; class Types { public static function answer():Int return 1; } class Nested {} function main():Void return;",
			consumerSource = "package identity.app; import identity.lib.Types as T; import identity.lib.Types.Nested as N; function main():Int { var value:N = new N(); return T.answer(); }";
		service.update("identity/lib/Types.hx", targetSource);
		service.analyze("identity.lib.Types");
		service.update("identity/app/Main.hx", consumerSource);
		service.analyze("identity.app.Main");

		var memberPosition = consumerSource.indexOf("T.answer") + "T.".length + 1,
			memberDefinition = service.definition("identity/app/Main.hx", memberPosition),
			memberReferences = service.references("identity/app/Main.hx", memberPosition),
			memberDeclaration = targetSource.indexOf("function answer");
		if (memberDefinition == null || memberDefinition.stale
			|| memberDefinition.path != "identity/lib/Types.hx"
			|| memberDefinition.span.start > memberDeclaration
			|| memberDefinition.span.end < memberDeclaration
			|| memberReferences.length < 2)
			throw 'package-qualified module alias did not preserve the static member identity: definition=${memberDefinition == null ? "null" : memberDefinition.path + ":" + memberDefinition.span.start}, references=${memberReferences.length}';

		var typePosition = consumerSource.indexOf("value:N") + "value:".length,
			typeDefinition = service.definition("identity/app/Main.hx", typePosition),
			typeReferences = service.references("identity/app/Main.hx", typePosition),
			typeDeclaration = targetSource.indexOf("class Nested");
		if (typeDefinition == null || typeDefinition.stale
			|| typeDefinition.path != "identity/lib/Types.hx"
			|| typeDefinition.span.start > typeDeclaration
			|| typeDefinition.span.end < typeDeclaration
			|| typeReferences.length < 2)
			throw 'secondary package type identity was not canonicalized: definition=${typeDefinition == null ? "null" : typeDefinition.path + ":" + typeDefinition.span.start}, references=${typeReferences.length}';

		var recoveredConsumer = StringTools.replace(consumerSource, "return T.answer();", "return T.answer(");
		service.update("identity/app/Main.hx", recoveredConsumer);
		var recoveredPosition = recoveredConsumer.indexOf("T.answer") + "T.".length + 1,
			recoveredDefinition = service.definition("identity/app/Main.hx", recoveredPosition),
			recoveredReferences = service.references("identity/app/Main.hx", recoveredPosition);
		if (recoveredDefinition == null || recoveredDefinition.stale
			|| recoveredDefinition.path != "identity/lib/Types.hx"
			|| recoveredDefinition.span.start > memberDeclaration
			|| recoveredDefinition.span.end < memberDeclaration
			|| recoveredReferences.length < 2)
			throw 'recovered package-qualified member identity diverged from exact analysis: definition=${recoveredDefinition == null ? "null" : recoveredDefinition.path + ":" + recoveredDefinition.span.start}, references=${recoveredReferences.length}';
	}

	static function assertGenericExternalEnumDetails():Void {
		var service = new LanguageService(),
			target = "package generic.enums; enum Result<T> { Value(value:T); } function main():Void return;",
			exactConsumer = "package generic.app; import generic.enums.Result; function main():Void { var result:Result<Int> = Result.Value(1); }";
		service.update("generic/enums/Result.hx", target);
		service.analyze("generic.enums.Result");
		service.update("generic/app/Main.hx", exactConsumer);
		service.analyze("generic.app.Main");
		var exactPosition = exactConsumer.indexOf("Result.Value") + "Result.".length + 1,
			exactHover = service.hover("generic/app/Main.hx", exactPosition),
			exactSignature = service.signatureHelp("generic/app/Main.hx", exactConsumer.lastIndexOf("Result.Value(") + "Result.Value(".length);
		if (exactHover != "Result.Value(value:Int)"
			|| exactSignature == null || exactSignature.label != "Result.Value(value:Int)")
			throw 'exact generic enum metadata was not substituted: hover=$exactHover, signature=${exactSignature == null ? "null" : exactSignature.label}';
		var recoveredConsumer = exactConsumer + " function unfinished(";
		service.update("generic/app/Main.hx", recoveredConsumer);
		var recoveredPosition = recoveredConsumer.indexOf("Result.Value") + "Result.".length + 1,
			recoveredHover = service.hover("generic/app/Main.hx", recoveredPosition),
			recoveredSignature = service.signatureHelp("generic/app/Main.hx", recoveredConsumer.lastIndexOf("Result.Value(") + "Result.Value(".length);
		if (recoveredHover != "Result.Value(value:Int)"
			|| recoveredSignature == null || recoveredSignature.label != "Result.Value(value:Int)")
			throw 'recovered generic enum metadata was not substituted: hover=$recoveredHover, signature=${recoveredSignature == null ? "null" : recoveredSignature.label}';
		var importedConsumer = "package generic.app; import generic.enums.Result; function main():Void { var result:Result<Int> = Value(1); }";
		service.update("generic/app/Imported.hx", importedConsumer);
		service.analyze("generic.app.Imported");
		var importedPosition = importedConsumer.indexOf("Value(1)") + 1,
			importedDefinition = service.definition("generic/app/Imported.hx", importedPosition),
			importedSignature = service.signatureHelp("generic/app/Imported.hx", importedConsumer.lastIndexOf("Value(") + "Value(".length),
			importedHover = service.hover("generic/app/Imported.hx", importedPosition);
		if (importedDefinition == null || importedDefinition.stale
			|| importedDefinition.path != "generic/enums/Result.hx"
			|| importedHover != "Result.Value(value:Int)"
			|| importedSignature == null || importedSignature.label != "Result.Value(value:Int)")
			throw 'exact imported generic enum metadata was not substituted: definition=${importedDefinition == null ? "null" : importedDefinition.path}, hover=$importedHover, signature=${importedSignature == null ? "null" : importedSignature.label}';
		var recoveredImportedConsumer = StringTools.replace(importedConsumer, "Value(1)", "Value(");
		service.update("generic/app/Imported.hx", recoveredImportedConsumer);
		var recoveredImportedPosition = recoveredImportedConsumer.lastIndexOf("Value(") + 1,
			recoveredImportedDefinition = service.definition("generic/app/Imported.hx", recoveredImportedPosition),
			recoveredImportedSignature = service.signatureHelp("generic/app/Imported.hx", recoveredImportedConsumer.length),
			recoveredImportedHover = service.hover("generic/app/Imported.hx", recoveredImportedPosition);
		if (recoveredImportedDefinition == null || recoveredImportedDefinition.stale
			|| recoveredImportedDefinition.path != "generic/enums/Result.hx"
			|| recoveredImportedHover != "Result.Value(value:Int)"
			|| recoveredImportedSignature == null || recoveredImportedSignature.label != "Result.Value(value:Int)")
			throw 'recovered imported generic enum metadata was not substituted: definition=${recoveredImportedDefinition == null ? "null" : recoveredImportedDefinition.path}, hover=$recoveredImportedHover, signature=${recoveredImportedSignature == null ? "null" : recoveredImportedSignature.label}';
		var memberTarget = "package generic.types; class Box<T> { public function get():T return cast null; } function main():Void return;",
			memberConsumer = "package generic.app; import generic.types.Box; function main():Int { var box:Box<Int> = new Box<Int>(); return box.get(); }";
		service.update("generic/types/Box.hx", memberTarget);
		service.analyze("generic.types.Box");
		service.update("generic/app/Member.hx", memberConsumer);
		service.analyze("generic.app.Member");
		var memberPosition = memberConsumer.indexOf("box.get") + "box.".length + 1,
			memberHover = service.hover("generic/app/Member.hx", memberPosition),
			memberSignature = service.signatureHelp("generic/app/Member.hx", memberConsumer.lastIndexOf("box.get(") + "box.get(".length);
		if (memberHover != "get():Int"
			|| memberSignature == null || memberSignature.label != "get():Int")
			throw 'exact generic external member metadata was not substituted: hover=$memberHover, signature=${memberSignature == null ? "null" : memberSignature.label}';
		var recoveredMemberConsumer = memberConsumer + " function unfinished(";
		service.update("generic/app/Member.hx", recoveredMemberConsumer);
		var recoveredMemberPosition = recoveredMemberConsumer.indexOf("box.get") + "box.".length + 1,
			recoveredMemberHover = service.hover("generic/app/Member.hx", recoveredMemberPosition),
			recoveredMemberSignature = service.signatureHelp("generic/app/Member.hx", recoveredMemberConsumer.lastIndexOf("box.get(") + "box.get(".length);
		if (recoveredMemberHover != "get():Int"
			|| recoveredMemberSignature == null || recoveredMemberSignature.label != "get():Int")
			throw 'recovered generic external member metadata was not substituted: hover=$recoveredMemberHover, signature=${recoveredMemberSignature == null ? "null" : recoveredMemberSignature.label}';
	}

	static function assertPackageVisibilityClosure():Void {
		var service = new LanguageService(),
			oneSource = "package visibility.one; function answer():Int return 1; class Choice {} function main():Void return;",
			twoSource = "package visibility.two; function answer():Int return 2; class Choice {} function main():Void return;",
			consumerSource = "package visibility.app; import visibility.one.*; function main():Int return answer();";
		service.update("visibility/one/One.hx", oneSource);
		service.analyze("visibility.one.One");
		service.update("visibility/two/Two.hx", twoSource);
		service.analyze("visibility.two.Two");
		service.update("visibility/app/Main.hx", consumerSource);
		service.analyze("visibility.app.Main");
		var position = consumerSource.indexOf("answer()") + 1,
			definition = service.definition("visibility/app/Main.hx", position),
			references = service.references("visibility/app/Main.hx", position);
		if (definition == null || definition.stale || definition.path != "visibility/one/One.hx"
			|| references.length < 2)
			throw 'wildcard package visibility did not select the imported identity: definition=${definition == null ? "null" : definition.path}, references=${references.length}';

		var ambiguousSource = "package visibility.app; import visibility.one.*; import visibility.two.*; function main():Int return answer();";
		service.update("visibility/app/Main.hx", ambiguousSource);
		if (service.definition("visibility/app/Main.hx", ambiguousSource.indexOf("answer()") + 1) != null
			|| service.references("visibility/app/Main.hx", ambiguousSource.indexOf("answer()") + 1).length != 0)
			throw "ambiguous wildcard package imports guessed a semantic identity";

		var samePackageService = new LanguageService(),
			samePackageTarget = "package visibility.same; function peer():Int return 1; function main():Void return;",
			samePackageConsumer = "package visibility.same; function main():Int return peer();";
		samePackageService.update("visibility/same/Peer.hx", samePackageTarget);
		samePackageService.analyze("visibility.same.Peer");
		samePackageService.update("visibility/same/Main.hx", samePackageConsumer);
		samePackageService.analyze("visibility.same.Main");
		var samePackagePosition = samePackageConsumer.indexOf("peer()") + 1,
			samePackageDefinition = samePackageService.definition("visibility/same/Main.hx", samePackagePosition),
			samePackageReferences = samePackageService.references("visibility/same/Main.hx", samePackagePosition);
		if (samePackageDefinition == null || samePackageDefinition.stale
			|| samePackageDefinition.path != "visibility/same/Peer.hx"
			|| samePackageReferences.length < 2)
			throw 'same-package function visibility did not preserve its identity: definition=${samePackageDefinition == null ? "null" : samePackageDefinition.path}, references=${samePackageReferences.length}';
		var samePackageRecovered = StringTools.replace(samePackageConsumer, "return peer();", "return peer(");
		samePackageService.update("visibility/same/Main.hx", samePackageRecovered);
		var recoveredPosition = samePackageRecovered.indexOf("peer(") + 1,
			recoveredDefinition = samePackageService.definition("visibility/same/Main.hx", recoveredPosition),
			recoveredReferences = samePackageService.references("visibility/same/Main.hx", recoveredPosition);
		if (recoveredDefinition == null || recoveredDefinition.stale
			|| recoveredDefinition.path != "visibility/same/Peer.hx"
			|| recoveredReferences.length < 2)
			throw 'recovered same-package function visibility lost its identity: definition=${recoveredDefinition == null ? "null" : recoveredDefinition.path}, references=${recoveredReferences.length}';

		var explicitFunctionService = new LanguageService(),
			explicitFunctionTarget = "package visibility.explicit; function answer():Int return 1; function main():Void return;",
			explicitFunctionConsumer = "package visibility.consumer; import visibility.explicit.Provider.answer as result; function main():Int return result();";
		explicitFunctionService.update("visibility/explicit/Provider.hx", explicitFunctionTarget);
		explicitFunctionService.analyze("visibility.explicit.Provider");
		explicitFunctionService.update("visibility/consumer/Main.hx", explicitFunctionConsumer);
		explicitFunctionService.analyze("visibility.consumer.Main");
		var explicitFunctionPosition = explicitFunctionConsumer.indexOf("result()") + 1,
			explicitFunctionDefinition = explicitFunctionService.definition("visibility/consumer/Main.hx", explicitFunctionPosition),
			explicitFunctionReferences = explicitFunctionService.references("visibility/consumer/Main.hx", explicitFunctionPosition);
		if (explicitFunctionDefinition == null || explicitFunctionDefinition.stale
			|| explicitFunctionDefinition.path != "visibility/explicit/Provider.hx"
			|| explicitFunctionReferences.length < 2)
			throw 'explicit function alias did not preserve its owning module identity: definition=${explicitFunctionDefinition == null ? "null" : explicitFunctionDefinition.path}, references=${explicitFunctionReferences.length}';

		var explicitFunctionRecovered = StringTools.replace(explicitFunctionConsumer, "return result();", "return result(");
		explicitFunctionService.update("visibility/consumer/Main.hx", explicitFunctionRecovered);
		var explicitFunctionRecoveredPosition = explicitFunctionRecovered.indexOf("result(") + 1,
			explicitFunctionRecoveredDefinition = explicitFunctionService.definition("visibility/consumer/Main.hx", explicitFunctionRecoveredPosition),
			explicitFunctionRecoveredReferences = explicitFunctionService.references("visibility/consumer/Main.hx", explicitFunctionRecoveredPosition);
		if (explicitFunctionRecoveredDefinition == null || explicitFunctionRecoveredDefinition.stale
			|| explicitFunctionRecoveredDefinition.path != "visibility/explicit/Provider.hx"
			|| explicitFunctionRecoveredReferences.length < 2)
			throw 'recovered explicit function alias lost its owning module identity: definition=${explicitFunctionRecoveredDefinition == null ? "null" : explicitFunctionRecoveredDefinition.path}, references=${explicitFunctionRecoveredReferences.length}';

		var enumImportService = new LanguageService(),
			enumImportTarget = "package visibility.enumlib; enum Result { Ready; Value(value:Int); } function main():Void return;",
			enumImportConsumer = "package visibility.enumapp; import visibility.enumlib.Result.Value; function main():Void { Value(1); }";
		enumImportService.update("visibility/enumlib/Result.hx", enumImportTarget);
		enumImportService.analyze("visibility.enumlib.Result");
		enumImportService.update("visibility/enumapp/Main.hx", enumImportConsumer);
		enumImportService.analyze("visibility.enumapp.Main");
		var enumImportPosition = enumImportConsumer.lastIndexOf("Value(1)") + 1,
			enumImportDefinition = enumImportService.definition("visibility/enumapp/Main.hx", enumImportPosition),
			enumImportReferences = enumImportService.references("visibility/enumapp/Main.hx", enumImportPosition),
			enumImportHover = enumImportService.hover("visibility/enumapp/Main.hx", enumImportPosition);
		if (enumImportDefinition == null || enumImportDefinition.stale
			|| enumImportDefinition.path != "visibility/enumlib/Result.hx"
			|| enumImportReferences.length < 2 || enumImportHover != "Result.Value(value:Int)")
			throw 'explicit enum-constructor import did not preserve its owner identity or hover: definition=${enumImportDefinition == null ? "null" : enumImportDefinition.path}, references=${enumImportReferences.length}, hover=${enumImportHover == null ? "null" : enumImportHover}';

		var enumImportRecovered = StringTools.replace(enumImportConsumer, "Value(1)", "Value(");
		enumImportService.update("visibility/enumapp/Main.hx", enumImportRecovered);
		var enumImportRecoveredPosition = enumImportRecovered.lastIndexOf("Value(") + 1,
			enumImportRecoveredDefinition = enumImportService.definition("visibility/enumapp/Main.hx", enumImportRecoveredPosition),
			enumImportRecoveredReferences = enumImportService.references("visibility/enumapp/Main.hx", enumImportRecoveredPosition),
			enumImportRecoveredHover = enumImportService.hover("visibility/enumapp/Main.hx", enumImportRecoveredPosition);
		if (enumImportRecoveredDefinition == null || enumImportRecoveredDefinition.stale
			|| enumImportRecoveredDefinition.path != "visibility/enumlib/Result.hx"
			|| enumImportRecoveredReferences.length < 2 || enumImportRecoveredHover != "Result.Value(value:Int)")
			throw 'recovered explicit enum-constructor import lost its owner identity or hover: definition=${enumImportRecoveredDefinition == null ? "null" : enumImportRecoveredDefinition.path}, references=${enumImportRecoveredReferences.length}, hover=${enumImportRecoveredHover == null ? "null" : enumImportRecoveredHover}';

		var enumAbstractImportService = new LanguageService(),
			enumAbstractImportTarget = "package visibility.flags; enum abstract Flags(Int) { var Ready = 1; } function main():Void return;",
			enumAbstractImportConsumer = "package visibility.flagapp; import visibility.flags.Flags.Ready; function main():Void { Ready; }";
		enumAbstractImportService.update("visibility/flags/Flags.hx", enumAbstractImportTarget);
		enumAbstractImportService.analyze("visibility.flags.Flags");
		enumAbstractImportService.update("visibility/flagapp/Main.hx", enumAbstractImportConsumer);
		enumAbstractImportService.analyze("visibility.flagapp.Main");
		var enumAbstractImportPosition = enumAbstractImportConsumer.lastIndexOf("Ready") + 1,
			enumAbstractImportDefinition = enumAbstractImportService.definition("visibility/flagapp/Main.hx", enumAbstractImportPosition),
			enumAbstractImportReferences = enumAbstractImportService.references("visibility/flagapp/Main.hx", enumAbstractImportPosition),
			enumAbstractImportHover = enumAbstractImportService.hover("visibility/flagapp/Main.hx", enumAbstractImportPosition);
		if (enumAbstractImportDefinition == null || enumAbstractImportDefinition.stale
			|| enumAbstractImportDefinition.path != "visibility/flags/Flags.hx"
			|| enumAbstractImportReferences.length < 2 || enumAbstractImportHover != "Ready:Int")
			throw 'explicit enum-abstract value import did not preserve its owner identity or hover: definition=${enumAbstractImportDefinition == null ? "null" : enumAbstractImportDefinition.path}, references=${enumAbstractImportReferences.length}, hover=${enumAbstractImportHover == null ? "null" : enumAbstractImportHover}';

		var enumAbstractImportRecovered = StringTools.replace(enumAbstractImportConsumer, "Ready;", "Ready");
		enumAbstractImportService.update("visibility/flagapp/Main.hx", enumAbstractImportRecovered);
		var enumAbstractImportRecoveredPosition = enumAbstractImportRecovered.lastIndexOf("Ready") + 1,
			enumAbstractImportRecoveredDefinition = enumAbstractImportService.definition("visibility/flagapp/Main.hx", enumAbstractImportRecoveredPosition),
			enumAbstractImportRecoveredReferences = enumAbstractImportService.references("visibility/flagapp/Main.hx", enumAbstractImportRecoveredPosition),
			enumAbstractImportRecoveredHover = enumAbstractImportService.hover("visibility/flagapp/Main.hx", enumAbstractImportRecoveredPosition);
		if (enumAbstractImportRecoveredDefinition == null || enumAbstractImportRecoveredDefinition.stale
			|| enumAbstractImportRecoveredDefinition.path != "visibility/flags/Flags.hx"
			|| enumAbstractImportRecoveredReferences.length < 2 || enumAbstractImportRecoveredHover != "Ready:Int")
			throw 'recovered explicit enum-abstract value import lost its owner identity or hover: definition=${enumAbstractImportRecoveredDefinition == null ? "null" : enumAbstractImportRecoveredDefinition.path}, references=${enumAbstractImportRecoveredReferences.length}, hover=${enumAbstractImportRecoveredHover == null ? "null" : enumAbstractImportRecoveredHover}';

		var enumTypeImportConsumer = "package visibility.enumapp; import visibility.enumlib.Result; function main():Void { Value(1); }";
		enumImportService.update("visibility/enumapp/TypeImport.hx", enumTypeImportConsumer);
		enumImportService.analyze("visibility.enumapp.TypeImport");
		var enumTypeImportPosition = enumTypeImportConsumer.lastIndexOf("Value(1)") + 1,
			enumTypeImportDefinition = enumImportService.definition("visibility/enumapp/TypeImport.hx", enumTypeImportPosition),
			enumTypeImportReferences = enumImportService.references("visibility/enumapp/TypeImport.hx", enumTypeImportPosition);
		if (enumTypeImportDefinition == null || enumTypeImportDefinition.stale
			|| enumTypeImportDefinition.path != "visibility/enumlib/Result.hx"
			|| enumTypeImportReferences.length < 2)
			throw 'enum-type import did not expose its unqualified constructor: definition=${enumTypeImportDefinition == null ? "null" : enumTypeImportDefinition.path}, references=${enumTypeImportReferences.length}';
		var enumTypeImportRecovered = StringTools.replace(enumTypeImportConsumer, "Value(1)", "Value(");
		enumImportService.update("visibility/enumapp/TypeImport.hx", enumTypeImportRecovered);
		var enumTypeImportRecoveredPosition = enumTypeImportRecovered.lastIndexOf("Value(") + 1,
			enumTypeImportRecoveredDefinition = enumImportService.definition("visibility/enumapp/TypeImport.hx", enumTypeImportRecoveredPosition),
			enumTypeImportRecoveredReferences = enumImportService.references("visibility/enumapp/TypeImport.hx", enumTypeImportRecoveredPosition);
		if (enumTypeImportRecoveredDefinition == null || enumTypeImportRecoveredDefinition.stale
			|| enumTypeImportRecoveredDefinition.path != "visibility/enumlib/Result.hx"
			|| enumTypeImportRecoveredReferences.length < 2)
			throw 'recovered enum-type import lost its unqualified constructor: definition=${enumTypeImportRecoveredDefinition == null ? "null" : enumTypeImportRecoveredDefinition.path}, references=${enumTypeImportRecoveredReferences.length}';
		var enumTypeImportSignature = enumImportService.signatureHelp("visibility/enumapp/TypeImport.hx", enumTypeImportRecovered.length);
		if (enumTypeImportSignature == null || enumTypeImportSignature.parameters.length != 1)
			throw 'recovered enum-type import lost constructor signature help: ${enumTypeImportSignature == null ? "null" : enumTypeImportSignature.label}';

		var enumAbstractTypeImportConsumer = "package visibility.flagapp; import visibility.flags.Flags; function main():Void { Ready; }";
		enumAbstractImportService.update("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportConsumer);
		enumAbstractImportService.analyze("visibility.flagapp.TypeImport");
		var enumAbstractTypeImportPosition = enumAbstractTypeImportConsumer.lastIndexOf("Ready") + 1,
			enumAbstractTypeImportDefinition = enumAbstractImportService.definition("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportPosition),
			enumAbstractTypeImportReferences = enumAbstractImportService.references("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportPosition);
		if (enumAbstractTypeImportDefinition == null || enumAbstractTypeImportDefinition.stale
			|| enumAbstractTypeImportDefinition.path != "visibility/flags/Flags.hx"
			|| enumAbstractTypeImportReferences.length < 2)
			throw 'enum-abstract type import did not expose its unqualified value: definition=${enumAbstractTypeImportDefinition == null ? "null" : enumAbstractTypeImportDefinition.path}, references=${enumAbstractTypeImportReferences.length}';
		var enumAbstractTypeImportRecovered = StringTools.replace(enumAbstractTypeImportConsumer, "Ready;", "Ready");
		enumAbstractImportService.update("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportRecovered);
		var enumAbstractTypeImportRecoveredPosition = enumAbstractTypeImportRecovered.lastIndexOf("Ready") + 1,
			enumAbstractTypeImportRecoveredDefinition = enumAbstractImportService.definition("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportRecoveredPosition),
			enumAbstractTypeImportRecoveredReferences = enumAbstractImportService.references("visibility/flagapp/TypeImport.hx", enumAbstractTypeImportRecoveredPosition);
		if (enumAbstractTypeImportRecoveredDefinition == null || enumAbstractTypeImportRecoveredDefinition.stale
			|| enumAbstractTypeImportRecoveredDefinition.path != "visibility/flags/Flags.hx"
			|| enumAbstractTypeImportRecoveredReferences.length < 2)
			throw 'recovered enum-abstract type import lost its unqualified value: definition=${enumAbstractTypeImportRecoveredDefinition == null ? "null" : enumAbstractTypeImportRecoveredDefinition.path}, references=${enumAbstractTypeImportRecoveredReferences.length}';

		var wildcardEnumImportService = new LanguageService(),
			wildcardEnumImportTarget = "package visibility.wildenum; enum Result { Value(value:Int); } function main():Void return;",
			wildcardEnumImportConsumer = "package visibility.wildenum.app; import visibility.wildenum.*; function main():Void { Value(1); }";
		wildcardEnumImportService.update("visibility/wildenum/Result.hx", wildcardEnumImportTarget);
		wildcardEnumImportService.analyze("visibility.wildenum.Result");
		wildcardEnumImportService.update("visibility/wildenum/app/Main.hx", wildcardEnumImportConsumer);
		wildcardEnumImportService.analyze("visibility.wildenum.app.Main");
		var wildcardEnumImportPosition = wildcardEnumImportConsumer.lastIndexOf("Value(1)") + 1,
			wildcardEnumImportDefinition = wildcardEnumImportService.definition("visibility/wildenum/app/Main.hx", wildcardEnumImportPosition),
			wildcardEnumImportReferences = wildcardEnumImportService.references("visibility/wildenum/app/Main.hx", wildcardEnumImportPosition);
		if (wildcardEnumImportDefinition == null || wildcardEnumImportDefinition.stale
			|| wildcardEnumImportDefinition.path != "visibility/wildenum/Result.hx"
			|| wildcardEnumImportReferences.length < 2)
			throw 'wildcard enum-constructor import did not retain identity: definition=${wildcardEnumImportDefinition == null ? "null" : wildcardEnumImportDefinition.path}, references=${wildcardEnumImportReferences.length}';
		var wildcardEnumImportRecovered = StringTools.replace(wildcardEnumImportConsumer, "Value(1)", "Value(");
		wildcardEnumImportService.update("visibility/wildenum/app/Main.hx", wildcardEnumImportRecovered);
		var wildcardEnumImportRecoveredPosition = wildcardEnumImportRecovered.lastIndexOf("Value(") + 1,
			wildcardEnumImportRecoveredDefinition = wildcardEnumImportService.definition("visibility/wildenum/app/Main.hx", wildcardEnumImportRecoveredPosition),
			wildcardEnumImportRecoveredReferences = wildcardEnumImportService.references("visibility/wildenum/app/Main.hx", wildcardEnumImportRecoveredPosition),
			wildcardEnumImportRecoveredHover = wildcardEnumImportService.hover("visibility/wildenum/app/Main.hx", wildcardEnumImportRecoveredPosition);
		if (wildcardEnumImportRecoveredDefinition == null || wildcardEnumImportRecoveredDefinition.stale
			|| wildcardEnumImportRecoveredDefinition.path != "visibility/wildenum/Result.hx"
			|| wildcardEnumImportRecoveredReferences.length < 2 || wildcardEnumImportRecoveredHover != "Result.Value(value:Int)")
			throw 'recovered wildcard enum-constructor import lost identity or hover: definition=${wildcardEnumImportRecoveredDefinition == null ? "null" : wildcardEnumImportRecoveredDefinition.path}, references=${wildcardEnumImportRecoveredReferences.length}, hover=${wildcardEnumImportRecoveredHover == null ? "null" : wildcardEnumImportRecoveredHover}';

		wildcardEnumImportService.update("visibility/wildenum/Flags.hx",
			"package visibility.wildenum; enum abstract Flags(Int) { var Ready = 1; } function main():Void return;");
		wildcardEnumImportService.analyze("visibility.wildenum.Flags");
		var wildcardEnumAbstractConsumer = "package visibility.wildenum.app; import visibility.wildenum.*; function main():Void { Ready; }";
		wildcardEnumImportService.update("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractConsumer);
		wildcardEnumImportService.analyze("visibility.wildenum.app.FlagsUse");
		var wildcardEnumAbstractPosition = wildcardEnumAbstractConsumer.lastIndexOf("Ready") + 1,
			wildcardEnumAbstractDefinition = wildcardEnumImportService.definition("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractPosition),
			wildcardEnumAbstractReferences = wildcardEnumImportService.references("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractPosition);
		if (wildcardEnumAbstractDefinition == null || wildcardEnumAbstractDefinition.stale
			|| wildcardEnumAbstractDefinition.path != "visibility/wildenum/Flags.hx"
			|| wildcardEnumAbstractReferences.length < 2)
			throw 'wildcard enum-abstract value import did not retain identity: definition=${wildcardEnumAbstractDefinition == null ? "null" : wildcardEnumAbstractDefinition.path}, references=${wildcardEnumAbstractReferences.length}';
		var wildcardEnumAbstractRecovered = StringTools.replace(wildcardEnumAbstractConsumer, "Ready;", "Ready");
		wildcardEnumImportService.update("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractRecovered);
		var wildcardEnumAbstractRecoveredPosition = wildcardEnumAbstractRecovered.lastIndexOf("Ready") + 1,
			wildcardEnumAbstractRecoveredDefinition = wildcardEnumImportService.definition("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractRecoveredPosition),
			wildcardEnumAbstractRecoveredReferences = wildcardEnumImportService.references("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractRecoveredPosition),
			wildcardEnumAbstractRecoveredHover = wildcardEnumImportService.hover("visibility/wildenum/app/FlagsUse.hx", wildcardEnumAbstractRecoveredPosition);
		if (wildcardEnumAbstractRecoveredDefinition == null || wildcardEnumAbstractRecoveredDefinition.stale
			|| wildcardEnumAbstractRecoveredDefinition.path != "visibility/wildenum/Flags.hx"
			|| wildcardEnumAbstractRecoveredReferences.length < 2 || wildcardEnumAbstractRecoveredHover != "Ready:Int")
			throw 'recovered wildcard enum-abstract value import lost identity or hover: definition=${wildcardEnumAbstractRecoveredDefinition == null ? "null" : wildcardEnumAbstractRecoveredDefinition.path}, references=${wildcardEnumAbstractRecoveredReferences.length}, hover=${wildcardEnumAbstractRecoveredHover == null ? "null" : wildcardEnumAbstractRecoveredHover}';

		var ambiguousEnumImportService = new LanguageService();
		ambiguousEnumImportService.update("visibility/enumone/Result.hx",
			"package visibility.enumone; enum Result { Value(value:Int); } function main():Void return;");
		ambiguousEnumImportService.update("visibility/enumtwo/Result.hx",
			"package visibility.enumtwo; enum Result { Value(value:Int); } function main():Void return;");
		var ambiguousEnumImportConsumer = "package visibility.enumapp; import visibility.enumone.Result.Value; import visibility.enumtwo.Result.Value; function main():Void { Value(1); }";
		ambiguousEnumImportService.update("visibility/enumapp/Ambiguous.hx", ambiguousEnumImportConsumer);
		var ambiguousEnumImportPosition = ambiguousEnumImportConsumer.lastIndexOf("Value(1)") + 1;
		if (ambiguousEnumImportService.definition("visibility/enumapp/Ambiguous.hx", ambiguousEnumImportPosition) != null
			|| ambiguousEnumImportService.references("visibility/enumapp/Ambiguous.hx", ambiguousEnumImportPosition).length != 0)
			throw "ambiguous explicit enum-constructor imports guessed a semantic identity";
		try
			ambiguousEnumImportService.analyze("visibility.enumapp.Ambiguous")
		catch (_:CompileError) {}
		if (ambiguousEnumImportService.definition("visibility/enumapp/Ambiguous.hx", ambiguousEnumImportPosition) != null
			|| ambiguousEnumImportService.references("visibility/enumapp/Ambiguous.hx", ambiguousEnumImportPosition).length != 0)
			throw "strict analysis guessed through ambiguous explicit enum-constructor imports";

		var secondaryEnumImportService = new LanguageService(),
			secondaryEnumImportTarget = "package visibility.secondary; enum Result { Value(value:Int); } class Container {} function main():Void return;",
			secondaryEnumImportConsumer = "package visibility.secondary.app; import visibility.secondary.Container.Result.Value as V; function main():Void { V(1); }";
		secondaryEnumImportService.update("visibility/secondary/Container.hx", secondaryEnumImportTarget);
		secondaryEnumImportService.analyze("visibility.secondary.Container");
		secondaryEnumImportService.update("visibility/secondary/app/Main.hx", secondaryEnumImportConsumer);
		secondaryEnumImportService.analyze("visibility.secondary.app.Main");
		var secondaryEnumImportPosition = secondaryEnumImportConsumer.lastIndexOf("V(1)") + 1,
			secondaryEnumImportDefinition = secondaryEnumImportService.definition("visibility/secondary/app/Main.hx", secondaryEnumImportPosition),
			secondaryEnumImportReferences = secondaryEnumImportService.references("visibility/secondary/app/Main.hx", secondaryEnumImportPosition);
		if (secondaryEnumImportDefinition == null || secondaryEnumImportDefinition.stale
			|| secondaryEnumImportDefinition.path != "visibility/secondary/Container.hx"
			|| secondaryEnumImportReferences.length < 2)
			throw 'secondary-module enum constructor import did not retain identity: definition=${secondaryEnumImportDefinition == null ? "null" : secondaryEnumImportDefinition.path}, references=${secondaryEnumImportReferences.length}';
		var secondaryEnumImportRecovered = StringTools.replace(secondaryEnumImportConsumer, "V(1)", "V(");
		secondaryEnumImportService.update("visibility/secondary/app/Main.hx", secondaryEnumImportRecovered);
		var secondaryEnumImportRecoveredPosition = secondaryEnumImportRecovered.lastIndexOf("V(") + 1,
			secondaryEnumImportRecoveredDefinition = secondaryEnumImportService.definition("visibility/secondary/app/Main.hx", secondaryEnumImportRecoveredPosition),
			secondaryEnumImportRecoveredReferences = secondaryEnumImportService.references("visibility/secondary/app/Main.hx", secondaryEnumImportRecoveredPosition);
		if (secondaryEnumImportRecoveredDefinition == null || secondaryEnumImportRecoveredDefinition.stale
			|| secondaryEnumImportRecoveredDefinition.path != "visibility/secondary/Container.hx"
			|| secondaryEnumImportRecoveredReferences.length < 2)
			throw 'recovered secondary-module enum constructor import did not retain identity: definition=${secondaryEnumImportRecoveredDefinition == null ? "null" : secondaryEnumImportRecoveredDefinition.path}, references=${secondaryEnumImportRecoveredReferences.length}';
		var secondaryEnumTypeImportConsumer = "package visibility.secondary.app; import visibility.secondary.Container.Result; function main():Void { Value(1); }";
		secondaryEnumImportService.update("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportConsumer);
		secondaryEnumImportService.analyze("visibility.secondary.app.TypeImport");
		var secondaryEnumTypeImportPosition = secondaryEnumTypeImportConsumer.lastIndexOf("Value(1)") + 1,
			secondaryEnumTypeImportDefinition = secondaryEnumImportService.definition("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportPosition),
			secondaryEnumTypeImportReferences = secondaryEnumImportService.references("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportPosition);
		if (secondaryEnumTypeImportDefinition == null || secondaryEnumTypeImportDefinition.stale
			|| secondaryEnumTypeImportDefinition.path != "visibility/secondary/Container.hx"
			|| secondaryEnumTypeImportReferences.length < 2)
			throw 'secondary-module enum type import did not retain its unqualified constructor: definition=${secondaryEnumTypeImportDefinition == null ? "null" : secondaryEnumTypeImportDefinition.path}, references=${secondaryEnumTypeImportReferences.length}';
		var secondaryEnumTypeImportRecovered = StringTools.replace(secondaryEnumTypeImportConsumer, "Value(1)", "Value("),
			secondaryEnumTypeImportRecoveredPosition = secondaryEnumTypeImportRecovered.lastIndexOf("Value(") + 1;
		secondaryEnumImportService.update("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportRecovered);
		var secondaryEnumTypeImportRecoveredDefinition = secondaryEnumImportService.definition("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportRecoveredPosition),
			secondaryEnumTypeImportRecoveredReferences = secondaryEnumImportService.references("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportRecoveredPosition),
			secondaryEnumTypeImportSignature = secondaryEnumImportService.signatureHelp("visibility/secondary/app/TypeImport.hx", secondaryEnumTypeImportRecovered.length);
		if (secondaryEnumTypeImportRecoveredDefinition == null || secondaryEnumTypeImportRecoveredDefinition.stale
			|| secondaryEnumTypeImportRecoveredDefinition.path != "visibility/secondary/Container.hx"
			|| secondaryEnumTypeImportRecoveredReferences.length < 2
			|| secondaryEnumTypeImportSignature == null || secondaryEnumTypeImportSignature.parameters.length != 1)
			throw 'recovered secondary-module enum type import lost constructor identity or signature: definition=${secondaryEnumTypeImportRecoveredDefinition == null ? "null" : secondaryEnumTypeImportRecoveredDefinition.path}, references=${secondaryEnumTypeImportRecoveredReferences.length}, signature=${secondaryEnumTypeImportSignature == null ? "null" : secondaryEnumTypeImportSignature.label}';
	}

	static function assertIncompleteDeclarations():Void {
		var missingFunctionName = new SourceFile("MissingFunction.hx", "function (");
		var missingFunctionResult = new Parser(new Lexer(missingFunctionName).tokenize()).parseProgramRecovering();
		if (missingFunctionResult.program.functions.length != 1 || missingFunctionResult.program.functions[0].name != "<missing>")
			throw "missing function name discarded the incomplete declaration";
		var placeholderService = new LanguageService();
		placeholderService.update("MissingFunction.hx", "function (");
		var placeholderModel = placeholderService.compiler.modules.get("MissingFunction").recoveredSemanticModel;
		if (placeholderModel == null)
			throw "missing-name recovery did not produce a semantic model";
		for (symbol in placeholderModel.index.symbols)
			if (symbol.name == "<missing>")
				throw "synthetic missing declaration leaked into semantic identity maps";

		var parameterSource = new SourceFile("Parameter.hx", "function test(a:Int,");
		var parameterResult = new Parser(new Lexer(parameterSource).tokenize()).parseProgramRecovering();
		if (parameterResult.program.functions.length != 1
			|| parameterResult.program.functions[0].name != "test"
			|| parameterResult.program.functions[0].arguments.length != 1)
			throw "unfinished parameter list discarded the function declaration";

		var adjacentParameterSource = new SourceFile("AdjacentParameter.hx", "function first(a:Int, function second():Void return;");
		var adjacentParameterResult = new Parser(new Lexer(adjacentParameterSource).tokenize()).parseProgramRecovering();
		if (adjacentParameterResult.program.functions.length != 2
			|| adjacentParameterResult.program.functions[0].name != "first"
			|| adjacentParameterResult.program.functions[0].arguments.length != 1
			|| adjacentParameterResult.program.functions[1].name != "second")
			throw "unfinished parameter list absorbed an adjacent function declaration";

		var missingParenthesisSource = new SourceFile("MissingParenthesis.hx", "function first\nfunction second():Void return;");
		var missingParenthesisResult = new Parser(new Lexer(missingParenthesisSource).tokenize()).parseProgramRecovering();
		if (missingParenthesisResult.program.functions.length != 2
			|| missingParenthesisResult.program.functions[0].name != "first"
			|| missingParenthesisResult.program.functions[1].name != "second")
			throw "function without a parameter list absorbed an adjacent declaration";

		var classSource = new SourceFile("Class.hx", "class Child extends");
		var classResult = new Parser(new Lexer(classSource).tokenize()).parseProgramRecovering();
		if (classResult.program.classes.length != 1 || classResult.program.classes[0].base == null)
			throw "unfinished extends clause discarded the class declaration";

		var genericDeclarationSource = new SourceFile("GenericDeclaration.hx", "class Child<\nfunction main():Void return;");
		var genericDeclarationResult = new Parser(new Lexer(genericDeclarationSource).tokenize()).parseProgramRecovering();
		if (genericDeclarationResult.program.classes.length != 1
			|| genericDeclarationResult.program.classes[0].typeParameters.length != 1
			|| genericDeclarationResult.program.functions.length != 1)
			throw "unfinished generic declaration discarded adjacent declarations";

		var methodSource = new SourceFile("Method.hx", "class Child { public function unfinished(");
		var methodResult = new Parser(new Lexer(methodSource).tokenize()).parseProgramRecovering();
		if (methodResult.program.classes.length != 1
			|| methodResult.program.classes[0].methods.length != 1
			|| methodResult.program.classes[0].methods[0].name != "unfinished")
			throw "unfinished method declaration discarded the class member";

		var interfaceMethodSource = new SourceFile("InterfaceMethod.hx", "interface Contract { function unfinished");
		var interfaceMethodResult = new Parser(new Lexer(interfaceMethodSource).tokenize()).parseProgramRecovering();
		if (interfaceMethodResult.program.interfaces.length != 1
			|| interfaceMethodResult.program.interfaces[0].methods.length != 1
			|| interfaceMethodResult.program.interfaces[0].methods[0].name != "unfinished")
			throw "unfinished interface method declaration discarded the interface member";

		var importSource = new SourceFile("Import.hx", "import model.\nfunction visible():Void return;");
		var importResult = new Parser(new Lexer(importSource).tokenize()).parseProgramRecovering();
		if (importResult.program.imports.length != 1
			|| importResult.program.imports[0] != "model"
			|| importResult.program.functions.length != 1
			|| importResult.program.functions[0].name != "visible")
			throw "unfinished import path discarded the following declaration";
		var wildcardImportSource = new SourceFile("WildcardImport.hx", "import model.*; function visible():Void return;");
		var wildcardImportResult = new Parser(new Lexer(wildcardImportSource).tokenize()).parseProgramRecovering();
		if (wildcardImportResult.program.imports.length != 1
			|| wildcardImportResult.program.imports[0] != "model.*"
			|| wildcardImportResult.program.functions.length != 1)
			throw "wildcard import path was not retained by recovery";

		var genericSource = new SourceFile("Generic.hx", "function main():Void { var values:Array<");
		var genericResult = new Parser(new Lexer(genericSource).tokenize()).parseProgramRecovering();
		if (genericResult.program.functions.length != 1 || genericResult.program.functions[0].statements.length != 1)
			throw "unfinished generic type discarded the enclosing function";
		var mapTypeSource = new SourceFile("MapTypePrefix.hx", "function main():Void { var values:Map<");
		var mapTypeResult = new Parser(new Lexer(mapTypeSource).tokenize()).parseProgramRecovering();
		if (mapTypeResult.program.functions.length != 1 || mapTypeResult.program.functions[0].statements.length != 1)
			throw "unfinished map type discarded the enclosing function";
		switch mapTypeResult.program.functions[0].statements[0] {
			case UninitializedDeclaration(_, type, _):
				switch type {
					case MapType(_, _):
					default: throw 'unfinished map type lost its type shape: $type';
				}
			default:
				throw "unfinished map type did not retain a declaration-shaped recovery node";
		}
		for (typeName in ["Array", "Map", "Null"]) {
			var typePrefixSource = new SourceFile("TypePrefix.hx", "function main():Void { var value:" + typeName);
			var typePrefixResult = new Parser(new Lexer(typePrefixSource).tokenize()).parseProgramRecovering();
			if (typePrefixResult.program.functions.length != 1 || typePrefixResult.program.functions[0].statements.length != 1)
				throw 'unfinished $typeName annotation discarded its enclosing function';
			if (Typer.typeRecovered(typePrefixResult.program) == null)
				throw 'tolerant typing abandoned unfinished $typeName annotation';
		}
		for (constructor in ["new Array", "new Array<", "new Map", "new Map<", "new List<"]) {
			var constructorSource = new SourceFile("Constructor.hx", "function main():Void return " + constructor);
			var constructorResult = new Parser(new Lexer(constructorSource).tokenize()).parseProgramRecovering();
			if (constructorResult.program.functions.length != 1 || constructorResult.program.functions[0].statements.length != 1)
				throw 'unfinished generic constructor discarded its enclosing function: $constructor';
			if (Typer.typeRecovered(constructorResult.program) == null)
				throw 'tolerant typing abandoned unfinished generic constructor: $constructor';
		}

		var memberSource = new SourceFile("Member.hx", "function main():Void return value.");
		var memberResult = new Parser(new Lexer(memberSource).tokenize()).parseProgramRecovering();
		if (memberResult.program.functions.length != 1 || memberResult.program.functions[0].statements.length != 1)
			throw 'unfinished member access discarded the function (${memberResult.program.functions.length}, ${memberResult.program.functions.length == 0 ? 0 : memberResult.program.functions[0].statements.length}): ${[for (diagnostic in memberResult.diagnostics) diagnostic.message].join("; ")}';
		switch memberResult.program.functions[0].statements[0] {
			case Return(Member(_, "", _), _):
			default:
				throw "unfinished member access did not retain a missing member node";
		}
		var memberBoundarySource = new SourceFile("MemberBoundary.hx", "function main():Void return value.\nfunction next():Void return;");
		var memberBoundaryResult = new Parser(new Lexer(memberBoundarySource).tokenize()).parseProgramRecovering().program;
		if (memberBoundaryResult.functions.length != 2 || memberBoundaryResult.functions[0].statements.length != 1)
			throw "unfinished member access discarded an adjacent declaration";
		switch memberBoundaryResult.functions[0].statements[0] {
			case Return(Member(_, "", _), _):
			default:
				throw "unfinished member access at a declaration boundary lost its recovery node";
		}

		var blockSource = new SourceFile("Block.hx", "function main():Void if (condition) {");
		var blockResult = new Parser(new Lexer(blockSource).tokenize()).parseProgramRecovering();
		if (blockResult.program.functions.length != 1 || blockResult.program.functions[0].statements.length != 1)
			throw "unfinished block discarded the enclosing function";
		switch blockResult.program.functions[0].statements[0] {
			case If(_, thenBranch, _, _):
				if (thenBranch.length != 0)
					throw "unfinished block unexpectedly changed its statement shape";
			default:
				throw "unfinished block did not retain the conditional node";
		}
		var missingBodySource = new SourceFile("MissingBody.hx", "function main():Void if (condition)");
		var missingBodyResult = new Parser(new Lexer(missingBodySource).tokenize()).parseProgramRecovering();
		if (missingBodyResult.program.functions.length != 1 || missingBodyResult.program.functions[0].statements.length != 1)
			throw "missing conditional body discarded the enclosing function";
		switch missingBodyResult.program.functions[0].statements[0] {
			case If(_, thenBranch, elseBranch, _) if (thenBranch.length == 0 && elseBranch.length == 0):
			default:
				throw "missing conditional body did not retain an empty recovered branch";
		}
		var missingBodyDiagnostic = false;
		for (diagnostic in missingBodyResult.diagnostics)
			if (diagnostic.message == "Expected statement or block")
				missingBodyDiagnostic = true;
		if (!missingBodyDiagnostic)
			throw "missing conditional body did not produce a focused recovery diagnostic";
		var missingElseBodySource = new SourceFile("MissingElseBody.hx", "function main():Void if (condition) else");
		var missingElseBodyResult = new Parser(new Lexer(missingElseBodySource).tokenize()).parseProgramRecovering();
		if (missingElseBodyResult.program.functions.length != 1 || missingElseBodyResult.program.functions[0].statements.length != 1)
			throw "missing else body discarded the enclosing function";
		switch missingElseBodyResult.program.functions[0].statements[0] {
			case If(_, thenBranch, elseBranch, _) if (thenBranch.length == 0 && elseBranch.length == 0):
			default:
				throw "missing else body did not retain both recovered branches";
		}

		var callSource = new SourceFile("Call.hx", "function main():Void return new Foo(");
		var callResult = new Parser(new Lexer(callSource).tokenize()).parseProgramRecovering();
		if (callResult.program.functions.length != 1 || callResult.program.functions[0].statements.length != 1)
			throw "unfinished constructor call discarded the enclosing function";

		var enumSource = new SourceFile("Enum.hx", "enum Choice {");
		var enumResult = new Parser(new Lexer(enumSource).tokenize()).parseProgramRecovering();
		if (enumResult.program.enums.length != 1)
			throw "unfinished enum declaration was abandoned at EOF";

		var enumBoundarySource = new SourceFile("EnumBoundary.hx", "enum Choice\nfunction visible():Void return;");
		var enumBoundaryResult = new Parser(new Lexer(enumBoundarySource).tokenize()).parseProgramRecovering();
		if (enumBoundaryResult.program.enums.length != 1
			|| enumBoundaryResult.program.functions.length != 1
			|| enumBoundaryResult.program.functions[0].name != "visible")
			throw "unfinished enum header discarded the following declaration";

		var enumCaseSource = new SourceFile("EnumCaseRecovery.hx", "enum Choice { (Int); visible; }");
		var enumCaseResult = new Parser(new Lexer(enumCaseSource).tokenize()).parseProgramRecovering();
		if (enumCaseResult.program.enums.length != 1
			|| enumCaseResult.program.enums[0].cases.length != 1
			|| enumCaseResult.program.enums[0].cases[0].name != "visible")
			throw "malformed enum case discarded the following case";

		var interfaceMemberSource = new SourceFile("InterfaceMemberRecovery.hx", "interface Contract { malformed; function visible():Int; }");
		var interfaceMemberResult = new Parser(new Lexer(interfaceMemberSource).tokenize()).parseProgramRecovering();
		if (interfaceMemberResult.program.interfaces.length != 1
			|| interfaceMemberResult.program.interfaces[0].methods.length != 1
			|| interfaceMemberResult.program.interfaces[0].methods[0].name != "visible")
			throw "malformed interface member discarded the following method";

		var abstractSource = new SourceFile("AbstractBoundary.hx", "abstract Value\nfunction visible():Void return;");
		var abstractResult = new Parser(new Lexer(abstractSource).tokenize()).parseProgramRecovering();
		if (abstractResult.program.abstracts.length != 1
			|| abstractResult.program.functions.length != 1
			|| abstractResult.program.functions[0].name != "visible")
			throw "unfinished abstract header discarded the following declaration";

		var enumAbstractSource = new SourceFile("EnumAbstractBoundary.hx", "enum abstract Flags\nfunction visible():Void return;");
		var enumAbstractResult = new Parser(new Lexer(enumAbstractSource).tokenize()).parseProgramRecovering();
		if (enumAbstractResult.program.enumAbstracts.length != 1
			|| enumAbstractResult.program.functions.length != 1
			|| enumAbstractResult.program.functions[0].name != "visible")
			throw "unfinished enum abstract header discarded the following declaration";

		var abstractMemberSource = new SourceFile("AbstractMemberRecovery.hx",
			"abstract Value(Int) { public malformed; public function visible():Int return 1; }");
		var abstractMemberResult = new Parser(new Lexer(abstractMemberSource).tokenize()).parseProgramRecovering();
		if (abstractMemberResult.program.abstracts.length != 1
			|| abstractMemberResult.program.abstracts[0].methods.length != 1
			|| abstractMemberResult.program.abstracts[0].methods[0].name != "visible")
			throw "malformed abstract member discarded the following method";

		var enumAbstractValueSource = new SourceFile("EnumAbstractValueRecovery.hx", "enum abstract Flags(Int) { var malformed = ; var visible = 1; }");
		var enumAbstractValueResult = new Parser(new Lexer(enumAbstractValueSource).tokenize()).parseProgramRecovering();
		if (enumAbstractValueResult.program.enumAbstracts.length != 1
			|| enumAbstractValueResult.program.enumAbstracts[0].values.length != 2
			|| enumAbstractValueResult.program.enumAbstracts[0].values[1].name != "visible")
			throw "malformed enum abstract value discarded the following value";
		switch enumAbstractValueResult.program.enumAbstracts[0].values[0].value {
			case ErrorExpression(_):
			default:
				throw "malformed enum abstract value did not retain an error expression";
		}
		if (Typer.typeRecovered(enumAbstractValueResult.program) == null)
			throw "malformed enum abstract value aborted tolerant typing";

		var controlSource = new SourceFile("Control.hx", "function main():Void { try { return; } for (");
		var controlResult = new Parser(new Lexer(controlSource).tokenize()).parseProgramRecovering();
		if (controlResult.program.functions.length != 1 || controlResult.program.functions[0].statements.length != 2)
			throw "unfinished try/for constructs discarded the enclosing function";
		switch controlResult.program.functions[0].statements[1] {
			case ForIn(_, _, ErrorExpression(_), _, _):
			default:
				throw "unfinished for construct did not retain its missing iterable";
		}
	}

	static function assertPartialTypeFacts():Void {
		var expectedService = new LanguageService(),
			source = "class Foo {} function take(value:Foo):Void return; function main():Void return take(";
		expectedService.update("Expected.hx", source);
		var expectedModel = expectedService.compiler.modules.get("Expected").recoveredSemanticModel;
		if (expectedModel == null)
			throw "missing recovered semantic model for expected-type test";
		var expected = expectedModel.index.completionContext(source.length).expected;
		switch expected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'unfinished call did not retain expected Foo argument type: $expected';
		}

		var assignmentService = new LanguageService(),
			assignmentSource = "class Foo {} function main():Void { var value:Foo = new Foo(); value = ";
		assignmentService.update("ExpectedAssignment.hx", assignmentSource);
		var assignmentModel = assignmentService.compiler.modules.get("ExpectedAssignment").recoveredSemanticModel;
		if (assignmentModel == null)
			throw "missing recovered semantic model for assignment expected-type test";
		var assignmentExpected = assignmentModel.index.completionContext(assignmentSource.length).expected;
		switch assignmentExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'assignment did not retain expected Foo type: $assignmentExpected';
		}

		var returnService = new LanguageService(),
			returnSource = "class Foo {} function main():Foo return ";
		returnService.update("ExpectedReturn.hx", returnSource);
		var returnModel = returnService.compiler.modules.get("ExpectedReturn").recoveredSemanticModel;
		if (returnModel == null)
			throw "missing recovered semantic model for return expected-type test";
		var returnExpected = returnModel.index.completionContext(returnSource.length).expected;
		switch returnExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'return did not retain expected Foo type: $returnExpected';
		}

		var collectionService = new LanguageService(),
			collectionSource = "class Foo {} function main():Void { var values:Array<Foo> = [";
		collectionService.update("ExpectedCollection.hx", collectionSource);
		var collectionModel = collectionService.compiler.modules.get("ExpectedCollection").recoveredSemanticModel;
		if (collectionModel == null)
			throw "missing recovered semantic model for collection expected-type test";
		var collectionExpected = collectionModel.index.completionContext(collectionSource.length).expected;
		switch collectionExpected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'array literal did not retain expected Foo element type: $collectionExpected';
		}

		var builtinStringExpectedService = new LanguageService(),
			builtinStringExpectedSource = "function main(value:String):Void return value.indexOf(";
		builtinStringExpectedService.update("ExpectedStringMethod.hx", builtinStringExpectedSource);
		var builtinStringExpected = builtinStringExpectedService.completionContext("ExpectedStringMethod.hx", builtinStringExpectedSource.length);
		if (builtinStringExpected == null || builtinStringExpected.context.expected != TString)
			throw 'String method argument did not retain its expected type: ${builtinStringExpected == null ? "null" : Std.string(builtinStringExpected.context.expected)}';

		var builtinArrayExpectedService = new LanguageService(),
			builtinArrayExpectedSource = "function main(values:Array<Int>):Void return values.push(";
		builtinArrayExpectedService.update("ExpectedArrayMethod.hx", builtinArrayExpectedSource);
		var builtinArrayExpected = builtinArrayExpectedService.completionContext("ExpectedArrayMethod.hx", builtinArrayExpectedSource.length);
		if (builtinArrayExpected == null || builtinArrayExpected.context.expected != TInt)
			throw 'Array method argument did not retain its expected type: ${builtinArrayExpected == null ? "null" : Std.string(builtinArrayExpected.context.expected)}';

		var builtinMapExpectedService = new LanguageService(),
			builtinMapExpectedSource = "function main(values:Map<String,Int>):Void return values.get(";
		builtinMapExpectedService.update("ExpectedMapMethod.hx", builtinMapExpectedSource);
		var builtinMapExpected = builtinMapExpectedService.completionContext("ExpectedMapMethod.hx", builtinMapExpectedSource.length);
		if (builtinMapExpected == null || builtinMapExpected.context.expected != TString)
			throw 'Map method argument did not retain its expected type: ${builtinMapExpected == null ? "null" : Std.string(builtinMapExpected.context.expected)}';

		var objectService = new LanguageService(),
			objectSource = "class Foo {} typedef Options = { value:Foo }; function main():Void { var options:Options = { value: ";
		objectService.update("ExpectedObject.hx", objectSource);
		var objectModel = objectService.compiler.modules.get("ExpectedObject").recoveredSemanticModel;
		if (objectModel == null)
			throw "missing recovered semantic model for object-field expected-type test";
		var objectContext = objectModel.index.completionContext(objectSource.length);
		if (objectContext.kind != SemanticCompletionContextKind.ObjectField)
			throw 'object literal was classified as ${objectContext.kind} instead of ObjectField';
		switch objectContext.expected {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'object field did not retain expected Foo type: ${objectContext.expected}';
		}

		var astOnlyLoopSource = new SourceFile("AstOnlyLoopRecovery.hx",
			"class Item { public var member:Int; } function main(values:Array<Item>):Void { for (item in values) { item. } }");
		var astOnlyLoopTokens = new Lexer(astOnlyLoopSource).tokenize(),
			astOnlyLoopProgram = new Parser(astOnlyLoopTokens).parseProgramRecovering().program,
			astOnlyLoopModel = new SemanticModel(astOnlyLoopProgram, astOnlyLoopSource, 1, astOnlyLoopTokens);
		astOnlyLoopModel.indexRecoveredSyntax(astOnlyLoopProgram);
		astOnlyLoopModel.freeze();
		var astOnlyLoopPosition = astOnlyLoopSource.text.indexOf("item. }") + "item.".length,
			astOnlyLoopContext = astOnlyLoopModel.index.completionContext(astOnlyLoopPosition, "item");
		switch astOnlyLoopContext.receiver {
			case TInstance(NominalKind.Class, "Item", _):
			default:
				throw 'AST-only recovered loop lost its element type: ${astOnlyLoopContext.receiver}';
		}

		var astOnlyPatternSource = new SourceFile("AstOnlyPatternRecovery.hx",
			"class Payload { public var member:Int; } enum Choice<T> { Some(value:T); Empty; } function main(choice:Choice<Payload>):Void { switch (choice) { case Some(value): value. } }");
		var astOnlyPatternTokens = new Lexer(astOnlyPatternSource).tokenize(),
			astOnlyPatternProgram = new Parser(astOnlyPatternTokens).parseProgramRecovering().program,
			astOnlyPatternModel = new SemanticModel(astOnlyPatternProgram, astOnlyPatternSource, 1, astOnlyPatternTokens);
		astOnlyPatternModel.indexRecoveredSyntax(astOnlyPatternProgram);
		astOnlyPatternModel.freeze();
		var astOnlyPatternPosition = astOnlyPatternSource.text.indexOf("value. }") + "value.".length,
			astOnlyPatternContext = astOnlyPatternModel.index.completionContext(astOnlyPatternPosition, "value");
		switch astOnlyPatternContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered pattern lost its binding type: ${astOnlyPatternContext.receiver}';
		}

		var astOnlySwitchExpressionSource = new SourceFile("AstOnlySwitchExpressionRecovery.hx",
			"class Payload { public var member:Int; } enum Choice<T> { Some(value:T); Empty; } function main(choice:Choice<Payload>):Void { var selected = switch (choice) { case Some(value): value.; default: new Payload(); }; }");
		var astOnlySwitchExpressionTokens = new Lexer(astOnlySwitchExpressionSource).tokenize(),
			astOnlySwitchExpressionProgram = new Parser(astOnlySwitchExpressionTokens).parseProgramRecovering().program,
			astOnlySwitchExpressionModel = new SemanticModel(astOnlySwitchExpressionProgram, astOnlySwitchExpressionSource, 1,
				astOnlySwitchExpressionTokens);
		astOnlySwitchExpressionModel.indexRecoveredSyntax(astOnlySwitchExpressionProgram);
		astOnlySwitchExpressionModel.freeze();
		var astOnlySwitchExpressionPosition = astOnlySwitchExpressionSource.text.indexOf("value.;") + "value.".length,
			astOnlySwitchExpressionContext = astOnlySwitchExpressionModel.index.completionContext(astOnlySwitchExpressionPosition, "value");
		switch astOnlySwitchExpressionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered switch expression lost its binding type: ${astOnlySwitchExpressionContext.receiver}';
		}

		var astOnlyComprehensionSource = new SourceFile("AstOnlyComprehensionRecovery.hx",
			"class Payload { public var member:Int; } function main(values:Array<Payload>):Void { var selected = [for (item in values) item.]; }");
		var astOnlyComprehensionTokens = new Lexer(astOnlyComprehensionSource).tokenize(),
			astOnlyComprehensionProgram = new Parser(astOnlyComprehensionTokens).parseProgramRecovering().program,
			astOnlyComprehensionModel = new SemanticModel(astOnlyComprehensionProgram, astOnlyComprehensionSource, 1, astOnlyComprehensionTokens);
		astOnlyComprehensionModel.indexRecoveredSyntax(astOnlyComprehensionProgram);
		astOnlyComprehensionModel.freeze();
		var astOnlyComprehensionPosition = astOnlyComprehensionSource.text.indexOf("item.]") + "item.".length,
			astOnlyComprehensionContext = astOnlyComprehensionModel.index.completionContext(astOnlyComprehensionPosition, "item");
		switch astOnlyComprehensionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered comprehension lost its binding type: ${astOnlyComprehensionContext.receiver}';
		}

		var inferredComprehensionSource = new SourceFile("InferredComprehensionRecovery.hx",
			"class Payload { public var member:Int; } function main(values:Array<Payload>):Void { var selected = [for (item in values) item]; var result = selected[0]; result. }");
		var inferredComprehensionTokens = new Lexer(inferredComprehensionSource).tokenize(),
			inferredComprehensionProgram = new Parser(inferredComprehensionTokens).parseProgramRecovering().program,
			inferredComprehensionModel = new SemanticModel(inferredComprehensionProgram, inferredComprehensionSource, 1,
				inferredComprehensionTokens);
		inferredComprehensionModel.indexRecoveredSyntax(inferredComprehensionProgram);
		inferredComprehensionModel.freeze();
		var inferredComprehensionPosition = inferredComprehensionSource.text.indexOf("result. }") + "result.".length,
			inferredComprehensionContext = inferredComprehensionModel.index.completionContext(inferredComprehensionPosition, "result");
		switch inferredComprehensionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'inferred recovered comprehension lost its element type: ${inferredComprehensionContext.receiver}';
		}

		var memberComprehensionSource = new SourceFile("MemberComprehensionRecovery.hx",
			"class Payload { public var member:Int; } class Item { public var payload:Payload; } function main(values:Array<Item>):Void { var selected = [for (item in values) item.payload]; var result = selected[0]; result. }");
		var memberComprehensionTokens = new Lexer(memberComprehensionSource).tokenize(),
			memberComprehensionProgram = new Parser(memberComprehensionTokens).parseProgramRecovering().program,
			memberComprehensionModel = new SemanticModel(memberComprehensionProgram, memberComprehensionSource, 1, memberComprehensionTokens);
		memberComprehensionModel.indexRecoveredSyntax(memberComprehensionProgram);
		memberComprehensionModel.freeze();
		var memberComprehensionItemPosition = memberComprehensionSource.text.indexOf("item.payload]") + "item.payload".length,
			memberComprehensionItemContext = memberComprehensionModel.index.completionContext(memberComprehensionItemPosition, "item");
		switch memberComprehensionItemContext.receiver {
			case TInstance(NominalKind.Class, "Item", _):
			default:
				throw 'AST-only comprehension binding lost its receiver type: ${memberComprehensionItemContext.receiver}';
		}
		var memberComprehensionPayloadContext = memberComprehensionModel.index.completionContext(memberComprehensionItemPosition, "item.payload");
		switch memberComprehensionPayloadContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only comprehension member lost its direct type: ${memberComprehensionPayloadContext.receiver}';
		}
		var memberComprehensionPosition = memberComprehensionSource.text.indexOf("result. }") + "result.".length,
			memberComprehensionContext = memberComprehensionModel.index.completionContext(memberComprehensionPosition, "result");
		switch memberComprehensionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered comprehension member lost its element type: ${memberComprehensionContext.receiver}';
		}

		var nestedComprehensionSource = new SourceFile("NestedComprehensionRecovery.hx",
			"class Payload { public var member:Int; } class Item { public var children:Array<Payload>; } function main(values:Array<Item>):Void { var selected = [for (item in values) [for (child in item.children) child]]; var result = selected[0][0]; result. }");
		var nestedComprehensionTokens = new Lexer(nestedComprehensionSource).tokenize(),
			nestedComprehensionProgram = new Parser(nestedComprehensionTokens).parseProgramRecovering().program,
			nestedComprehensionModel = new SemanticModel(nestedComprehensionProgram, nestedComprehensionSource, 1, nestedComprehensionTokens);
		nestedComprehensionModel.indexRecoveredSyntax(nestedComprehensionProgram);
		nestedComprehensionModel.freeze();
		var nestedComprehensionPosition = nestedComprehensionSource.text.indexOf("result. }") + "result.".length,
			nestedComprehensionContext = nestedComprehensionModel.index.completionContext(nestedComprehensionPosition, "result");
		switch nestedComprehensionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only nested comprehension lost its outer binding type: ${nestedComprehensionContext.receiver}';
		}

		var astOnlyNestedCollectionSource = new SourceFile("AstOnlyNestedCollectionRecovery.hx",
			"class Payload { public var member:Int; } function main():Void { var values = [[broken], [new Payload()]]; var item = values[1][0]; item. }");
		var astOnlyNestedCollectionTokens = new Lexer(astOnlyNestedCollectionSource).tokenize(),
			astOnlyNestedCollectionProgram = new Parser(astOnlyNestedCollectionTokens).parseProgramRecovering().program,
			astOnlyNestedCollectionModel = new SemanticModel(astOnlyNestedCollectionProgram, astOnlyNestedCollectionSource, 1,
				astOnlyNestedCollectionTokens);
		astOnlyNestedCollectionModel.indexRecoveredSyntax(astOnlyNestedCollectionProgram);
		astOnlyNestedCollectionModel.freeze();
		var astOnlyNestedCollectionPosition = astOnlyNestedCollectionSource.text.indexOf("item. }") + "item.".length,
			astOnlyNestedCollectionContext = astOnlyNestedCollectionModel.index.completionContext(astOnlyNestedCollectionPosition, "item");
		switch astOnlyNestedCollectionContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered nested collection lost its stable element type: ${astOnlyNestedCollectionContext.receiver}';
		}

		var astOnlyIteratorSource = new SourceFile("AstOnlyIteratorRecovery.hx",
			"class Payload { public var member:Int; } function main(values:Array<Payload>):Void { var iterator = values.iterator(); var item = iterator.next(); item. }");
		var astOnlyIteratorTokens = new Lexer(astOnlyIteratorSource).tokenize(),
			astOnlyIteratorProgram = new Parser(astOnlyIteratorTokens).parseProgramRecovering().program,
			astOnlyIteratorModel = new SemanticModel(astOnlyIteratorProgram, astOnlyIteratorSource, 1, astOnlyIteratorTokens);
		astOnlyIteratorModel.indexRecoveredSyntax(astOnlyIteratorProgram);
		astOnlyIteratorModel.freeze();
		var astOnlyIteratorPosition = astOnlyIteratorSource.text.indexOf("item. }") + "item.".length,
			astOnlyIteratorContext = astOnlyIteratorModel.index.completionContext(astOnlyIteratorPosition, "item");
		switch astOnlyIteratorContext.receiver {
			case TInstance(NominalKind.Class, "Payload", _):
			default:
				throw 'AST-only recovered iterator method lost its element type: ${astOnlyIteratorContext.receiver}';
		}

		var patternService = new LanguageService(),
			patternSource = "enum Choice { One; Two(value:Int); } function main():Void { var choice:Choice = One; switch (choice) { case ";
		patternService.update("ExpectedPattern.hx", patternSource);
		var patternModel = patternService.compiler.modules.get("ExpectedPattern").recoveredSemanticModel;
		if (patternModel == null)
			throw "missing recovered semantic model for pattern completion test";
		var patternContext = patternModel.index.completionContext(patternSource.length);
		if (patternContext.kind != SemanticCompletionContextKind.Pattern)
			throw 'switch pattern was classified as ${patternContext.kind} instead of Pattern';
		switch patternContext.expected {
			case TInstance(NominalKind.Enum, "Choice", _):
			default:
				throw 'switch pattern did not retain expected Choice type: ${patternContext.expected}';
		}
		var patternNames = [
			for (item in patternService.complete("ExpectedPattern.hx", patternSource.length))
				item.label
		];
		if (patternNames.indexOf("One") < 0 || patternNames.indexOf("Two") < 0)
			throw "switch pattern completion did not expose expected enum cases";

		var overrideService = new LanguageService(),
			overrideSource = "class Base { public function render(value:Int):Int return value; } class Child extends Base { override ";
		overrideService.update("ExpectedOverride.hx", overrideSource);
		var overrideModel = overrideService.compiler.modules.get("ExpectedOverride").recoveredSemanticModel;
		if (overrideModel == null)
			throw "missing recovered semantic model for override completion test";
		var overrideContext = overrideModel.index.completionContext(overrideSource.length);
		if (overrideContext.kind != SemanticCompletionContextKind.Override)
			throw 'override completion was classified as ${overrideContext.kind} instead of Override';
		switch overrideContext.receiver {
			case TInstance(NominalKind.Class, "Base", _):
			default:
				throw 'override completion did not retain Base as its owner: ${overrideContext.receiver}';
		}
		var overrideNames = [
			for (item in overrideService.complete("ExpectedOverride.hx", overrideSource.length))
				item.label
		];
		if (overrideNames.indexOf("render") < 0)
			throw "override completion did not expose the inherited method";

		var genericContextService = new LanguageService(),
			genericContextSource = "class Foo {} function identity<T:Foo>(value:T):T { var result:T = value; return result; }";
		genericContextService.update("GenericContext.hx", genericContextSource);
		var genericContextModel = genericContextService.compiler.modules.get("GenericContext").recoveredSemanticModel,
			genericTypePosition = genericContextSource.indexOf("result:T") + "result:T".length,
			genericContext = genericContextModel == null ? null : genericContextModel.index.completionContext(genericTypePosition),
			genericTypeNames = [for (item in genericContextService.complete("GenericContext.hx", genericTypePosition)) item.label];
		if (genericContext == null
			|| genericContext.typeParameters.indexOf("T") < 0
			|| genericTypeNames.indexOf("T") < 0)
			throw "generic type parameter was not retained in recovered type completion";
		switch genericContext.expected {
			case TTypeParameter(_, "T"):
			default:
				throw 'generic expected type was not retained: ${genericContext.expected}';
		}
		var genericMemberService = new LanguageService(),
			genericMemberSource = "class Box<T> { public var value:T; public function get():T return value; } function main():Void { var box = new Box<Int>(); box.";
		genericMemberService.update("GenericMember.hx", genericMemberSource);
		var genericMemberCompletion = genericMemberService.complete("GenericMember.hx", genericMemberSource.length),
			genericMemberNames = [for (item in genericMemberCompletion) item.label],
			genericValueDetail:Null<String> = null,
			genericGetDetail:Null<String> = null;
		for (item in genericMemberCompletion) {
			if (item.label == "value")
				genericValueDetail = item.detail;
			if (item.label == "get")
				genericGetDetail = item.detail;
		}
		if (genericMemberNames.indexOf("value") < 0
			|| genericValueDetail != "value:Int"
			|| genericGetDetail != "get():Int")
			throw "generic recovered receiver did not retain member completion";
		var genericArgumentService = new LanguageService(),
			genericArgumentSource = "class Box<T> { public function set(value:T):Void return; } function main():Void { var box = new Box<Int>(); box.set(";
		genericArgumentService.update("GenericArgument.hx", genericArgumentSource);
		var genericArgumentContext = genericArgumentService.completionContext("GenericArgument.hx", genericArgumentSource.length);
		if (genericArgumentContext == null || genericArgumentContext.context.expected != TInt)
			throw 'generic method argument did not retain the inferred receiver type: ${genericArgumentContext == null ? "null" : Std.string(genericArgumentContext.context.expected)}';
		var genericInheritanceService = new LanguageService(),
			genericInheritanceSource = "class Base<T> { public var value:T; public function get():T return value; } class Child<U> extends Base<U> {} function main():Void { var child = new Child<Int>(); child.";
		genericInheritanceService.update("GenericInheritance.hx", genericInheritanceSource);
		var genericInheritanceCompletion = genericInheritanceService.complete("GenericInheritance.hx", genericInheritanceSource.length),
			genericInheritanceValue:Null<String> = null,
			genericInheritanceGet:Null<String> = null;
		for (item in genericInheritanceCompletion) {
			if (item.label == "value")
				genericInheritanceValue = item.detail;
			if (item.label == "get")
				genericInheritanceGet = item.detail;
		}
		if (genericInheritanceValue != "value:Int" || genericInheritanceGet != "get():Int")
			throw 'generic inherited member types were not substituted: value=$genericInheritanceValue, get=$genericInheritanceGet';
		var exactGenericInheritanceService = new LanguageService(),
			exactGenericInheritanceSource = "class Base<T> { public function get():T return cast null; } class Child<U> extends Base<U> {} function main():Int { var child:Child<Int> = new Child<Int>(); return child.get(); }";
		exactGenericInheritanceService.update("ExactGenericInheritance.hx", exactGenericInheritanceSource);
		exactGenericInheritanceService.analyze("ExactGenericInheritance");
		var exactGenericInheritancePosition = exactGenericInheritanceSource.indexOf("child.get") + "child.".length + 1,
			exactGenericInheritanceHover = exactGenericInheritanceService.hover("ExactGenericInheritance.hx", exactGenericInheritancePosition),
			exactGenericInheritanceReferences = exactGenericInheritanceService.references("ExactGenericInheritance.hx", exactGenericInheritancePosition),
			exactGenericInheritanceSignature = exactGenericInheritanceService.signatureHelp("ExactGenericInheritance.hx",
				exactGenericInheritanceSource.lastIndexOf("child.get(") + "child.get(".length);
		if (exactGenericInheritanceHover != "get():Int"
			|| exactGenericInheritanceSignature == null || exactGenericInheritanceSignature.label != "get():Int"
			|| exactGenericInheritanceReferences.length < 2)
			throw 'exact inherited generic member metadata or identity was not preserved: hover=$exactGenericInheritanceHover, signature=${exactGenericInheritanceSignature == null ? "null" : exactGenericInheritanceSignature.label}, references=${exactGenericInheritanceReferences.length}';
		var genericInheritanceCallSource = genericInheritanceSource.substring(0, genericInheritanceSource.length - "child.".length) + "child.get(",
			genericInheritanceCallPosition = genericInheritanceCallSource.length;
		genericInheritanceService.update("GenericInheritance.hx", genericInheritanceCallSource);
		var genericInheritanceSignature = genericInheritanceService.signatureHelp("GenericInheritance.hx", genericInheritanceCallPosition);
		if (genericInheritanceSignature == null || genericInheritanceSignature.label != "get():Int")
			throw 'generic inherited signature did not retain the receiver type: ${genericInheritanceSignature == null ? "null" : genericInheritanceSignature.label}';
		var genericInheritanceHoverPosition = genericInheritanceCallSource.indexOf("child.get") + "child.".length + 1,
			genericInheritanceHover = genericInheritanceService.hover("GenericInheritance.hx", genericInheritanceHoverPosition);
		if (genericInheritanceHover != "get():Int")
			throw 'generic inherited hover did not retain the receiver type: $genericInheritanceHover';
		var genericNavigationSource = genericInheritanceSource.substring(0, genericInheritanceSource.length - "child.".length) + "child.value;",
			genericNavigationPosition = genericNavigationSource.lastIndexOf("child.value") + "child.".length + 1;
		genericInheritanceService.update("GenericInheritance.hx", genericNavigationSource);
		var genericNavigationDefinition = genericInheritanceService.definition("GenericInheritance.hx", genericNavigationPosition),
			genericNavigationReferences = genericInheritanceService.references("GenericInheritance.hx", genericNavigationPosition);
		if (genericNavigationDefinition == null || genericNavigationDefinition.stale
			|| genericNavigationDefinition.span.start != genericNavigationSource.indexOf("var value")
			|| genericNavigationReferences.length < 2)
			throw "recovered inherited member navigation did not retain its current semantic identity";
		var genericInterfaceService = new LanguageService(),
			genericInterfaceSource = "interface Contract<T> { function get():T; } class Impl<U> implements Contract<U> {} function main():Void { var impl = new Impl<Int>(); impl.";
		genericInterfaceService.update("GenericInterface.hx", genericInterfaceSource);
		var genericInterfaceCompletion = genericInterfaceService.complete("GenericInterface.hx", genericInterfaceSource.length),
			genericInterfaceGet:Null<String> = null;
		for (item in genericInterfaceCompletion)
			if (item.label == "get")
				genericInterfaceGet = item.detail;
		if (genericInterfaceGet != "get():Int")
			throw 'generic interface member type was not substituted: $genericInterfaceGet';
		var abstractMemberService = new LanguageService(),
			abstractMemberSource = "abstract Box<T>(T) { public function get():T return this; } function main():Void { var box:Box<Int>; box.";
		abstractMemberService.update("AbstractMember.hx", abstractMemberSource);
		var abstractMemberGet:Null<String> = null;
		for (item in abstractMemberService.complete("AbstractMember.hx", abstractMemberSource.length))
			if (item.label == "get")
				abstractMemberGet = item.detail;
		if (abstractMemberGet != "get():Int")
			throw 'recovered abstract member type was not substituted: $abstractMemberGet';
		var abstractConstructorService = new LanguageService(),
			abstractConstructorSource = "abstract Box<T>(T) { public function new(value:T) { this = value; } } function main():Void { new Box<Int>(";
		abstractConstructorService.update("AbstractConstructor.hx", abstractConstructorSource);
		var abstractConstructorPosition = abstractConstructorSource.indexOf("Box<Int>") + 1,
			abstractConstructorDefinition = abstractConstructorService.definition("AbstractConstructor.hx", abstractConstructorPosition),
			abstractConstructorSignature = abstractConstructorService.signatureHelp("AbstractConstructor.hx", abstractConstructorSource.length);
		if (abstractConstructorDefinition == null || abstractConstructorDefinition.stale
			|| abstractConstructorDefinition.span.start > abstractConstructorSource.indexOf("Box<T>")
			|| abstractConstructorDefinition.span.end < abstractConstructorSource.indexOf("Box<T>") + "Box<T>".length
			|| abstractConstructorSignature == null || abstractConstructorSignature.label != "Box(value:Int)")
			throw 'recovered generic abstract constructor lost identity or substitution: definition=${abstractConstructorDefinition == null ? "null" : abstractConstructorDefinition.span.start + ":" + abstractConstructorDefinition.stale}, signature=${abstractConstructorSignature == null ? "null" : abstractConstructorSignature.label}';
		var exactAbstractConstructorService = new LanguageService(),
			exactAbstractConstructorSource = abstractConstructorSource + ") ; }";
		exactAbstractConstructorService.update("ExactAbstractConstructor.hx", exactAbstractConstructorSource);
		try
			exactAbstractConstructorService.analyze("ExactAbstractConstructor")
		catch (_:CompileError) {}
		var exactAbstractConstructorPosition = exactAbstractConstructorSource.indexOf("Box<Int>") + 1,
			exactAbstractConstructorDefinition = exactAbstractConstructorService.definition("ExactAbstractConstructor.hx", exactAbstractConstructorPosition),
			exactAbstractConstructorReferences = exactAbstractConstructorService.references("ExactAbstractConstructor.hx", exactAbstractConstructorPosition);
		if (exactAbstractConstructorDefinition == null
			|| exactAbstractConstructorDefinition.stale
			|| exactAbstractConstructorDefinition.span.start > exactAbstractConstructorSource.indexOf("Box<T>")
			|| exactAbstractConstructorDefinition.span.end < exactAbstractConstructorSource.indexOf("Box<T>") + "Box<T>".length
			|| exactAbstractConstructorReferences.length < 2)
			throw "exact generic abstract constructor did not preserve its authoritative identity";
		var exactAbstractService = new LanguageService(),
			exactAbstractSource = "abstract Box(Int) { public function new(value:Int) { this = value; } public function get():Void return; } function main():Void { var box = new Box(1); box.get(); }";
		exactAbstractService.update("ExactAbstract.hx", exactAbstractSource);
		exactAbstractService.analyze("ExactAbstract");
		var exactAbstractPosition = exactAbstractSource.lastIndexOf("get") + 1,
			exactAbstractDefinition = exactAbstractService.definition("ExactAbstract.hx", exactAbstractPosition),
			exactAbstractReferences = exactAbstractService.references("ExactAbstract.hx", exactAbstractPosition);
		if (exactAbstractDefinition == null
			|| exactAbstractDefinition.path != "ExactAbstract.hx"
			|| exactAbstractReferences.length < 2)
			throw "exact abstract member navigation did not resolve its authoritative identity";

		var exactGenericService = new LanguageService(),
			exactGenericSource = "function identity<T>(value:T):T return value; function main():Int return identity(1);";
		exactGenericService.update("ExactGeneric.hx", exactGenericSource);
		exactGenericService.analyze("ExactGeneric");
		var exactGenericPosition = exactGenericSource.lastIndexOf("identity") + 1,
			exactGenericDefinition = exactGenericService.definition("ExactGeneric.hx", exactGenericPosition),
			exactGenericReferences = exactGenericService.references("ExactGeneric.hx", exactGenericPosition);
		var exactGenericDeclaration = exactGenericSource.indexOf("identity");
		if (exactGenericDefinition == null
			|| exactGenericDefinition.span.start > exactGenericDeclaration
			|| exactGenericDefinition.span.end < exactGenericDeclaration
			|| exactGenericReferences.length < 2)
			throw "exact generic function navigation did not resolve its source identity";

		var exactInheritanceService = new LanguageService(),
			exactInheritanceSource = "class Base { public var value:Int; } class Child extends Base {} function main():Int { var child:Child = new Child(); return child.value; }";
		exactInheritanceService.update("ExactInheritance.hx", exactInheritanceSource);
		exactInheritanceService.analyze("ExactInheritance");
		var exactInheritanceUse = exactInheritanceSource.lastIndexOf("value"),
			exactInheritanceDeclaration = exactInheritanceSource.indexOf("value"),
			exactInheritanceDefinition = exactInheritanceService.definition("ExactInheritance.hx", exactInheritanceUse + 1),
			exactInheritanceReferences = exactInheritanceService.references("ExactInheritance.hx", exactInheritanceUse + 1);
		if (exactInheritanceDefinition == null
			|| exactInheritanceDefinition.span.start > exactInheritanceDeclaration
			|| exactInheritanceDefinition.span.end < exactInheritanceDeclaration
			|| exactInheritanceReferences.length < 2)
			throw 'exact inherited member navigation did not resolve its source identity: definition=${exactInheritanceDefinition == null ? "null" : exactInheritanceDefinition.span.start + "/" + exactInheritanceDefinition.span.end}, references=${exactInheritanceReferences.length}';

		var importService = new LanguageService();
		importService.update("lib/Widget.hx", "class Widget {} function main():Void return;");
		try
			importService.analyze("lib.Widget")
		catch (_:CompileError) {}
		var importSource = "import Wid";
		importService.update("ImportRecovery.hx", importSource);
		var importModel = importService.compiler.modules.get("ImportRecovery").recoveredSemanticModel;
		if (importModel == null || importModel.index.completionContext(importSource.length).kind != SemanticCompletionContextKind.Import)
			throw "unfinished import did not expose an import completion context";
		var importNames = [
			for (item in importService.complete("ImportRecovery.hx", importSource.length))
				item.label
		];
		if (importNames.indexOf("Widget") < 0)
			throw "unfinished import did not expose an importable declaration";

		var errorService = new LanguageService(),
			errorSource = "function main():Void { var broken =";
		errorService.update("ErrorType.hx", errorSource);
		var errorModel = errorService.compiler.modules.get("ErrorType").recoveredSemanticModel;
		if (errorModel == null)
			throw "missing recovered semantic model for error-type test";
		var locals = errorModel.index.completionContext(errorSource.length).locals,
			foundError = false;
		for (local in locals)
			if (local.name == "broken")
				switch local.type {
					case TError:
						foundError = true;
					default:
				}
		if (!foundError)
			throw "incomplete initializer did not retain an explicit error type";

		var errorStatementSource = new SourceFile("ErrorStatementTyping.hx", "function main():Void { if () return; var after:Int = 1; }");
		var errorStatementProgram = new Parser(new Lexer(errorStatementSource).tokenize()).parseProgramRecovering().program,
			errorStatementTyped = Typer.typeRecovered(errorStatementProgram);
		if (errorStatementTyped == null
			|| errorStatementTyped.functions.length != 1
			|| errorStatementTyped.functions[0].statements.length < 2)
			throw "tolerant typing discarded a valid declaration after an ErrorStatement";

		var compoundErrorSource = new SourceFile("CompoundErrorTyping.hx",
			"function main():Void { if (broken) { var inside:Int = 1; } var after:Int = 2; }");
		var compoundErrorProgram = new Parser(new Lexer(compoundErrorSource).tokenize()).parseProgramRecovering().program,
			compoundErrorTyped = Typer.typeRecovered(compoundErrorProgram);
		var retainedCompoundLocal = false;
		if (compoundErrorTyped != null && compoundErrorTyped.functions.length == 1)
			switch compoundErrorTyped.functions[0].statements[0] {
				case TIf(_, thenBranch, _, _):
					for (statement in thenBranch)
						switch statement {
							case TVar(_, _, _): retainedCompoundLocal = true;
							default:
						}
				default:
			}
		if (!retainedCompoundLocal)
			throw "tolerant typing discarded a valid local inside a conditionally malformed branch";

		var recoveredConditionSource = new SourceFile("RecoveredConditionTyping.hx",
			"class Item { public var member:Int; } function main():Void { var item:Item = new Item(); if (item) { item.member; } }");
		var recoveredConditionProgram = new Parser(new Lexer(recoveredConditionSource).tokenize()).parseProgramRecovering().program,
			recoveredConditionTyped = Typer.typeRecovered(recoveredConditionProgram);
		var retainedConditionType = false,
			retainedConditionMember = false;
		if (recoveredConditionTyped != null && recoveredConditionTyped.functions.length == 1)
			switch recoveredConditionTyped.functions[0].statements[1] {
				case TIf(condition, thenBranch, _, _):
					switch condition.type {
						case TInstance(NominalKind.Class, "Item", _): retainedConditionType = true;
						default:
					}
					for (statement in thenBranch)
						switch statement {
							case TExpression(expression, _):
								switch expression.expression {
									case TField(_, "member"): retainedConditionMember = true;
									default:
								}
							default:
						}
				default:
			}
		if (!retainedConditionType || !retainedConditionMember)
			throw "compound recovery discarded a typed condition or branch expression";

		var recoveredForInSource = new SourceFile("RecoveredForInTyping.hx",
			"class Item { public var member:Int; } function main(map:Map<Bool, Item>):Void { for (key => value in map) { value.member; } }");
		var recoveredForInProgram = new Parser(new Lexer(recoveredForInSource).tokenize()).parseProgramRecovering().program,
			recoveredForInTyped = Typer.typeRecovered(recoveredForInProgram);
		var retainedForInValue = false,
			retainedForInMember = false;
		if (recoveredForInTyped != null && recoveredForInTyped.functions.length == 1)
			switch recoveredForInTyped.functions[0].statements[0] {
				case TForIn(_, valueName, iterable, body, _):
					if (valueName != null)
						switch iterable.type {
							case TMap(_, TInstance(NominalKind.Class, "Item", _)): retainedForInValue = true;
							default:
						}
					for (statement in body)
						switch statement {
							case TExpression(expression, _):
								switch expression.expression {
									case TField(_, "member"): retainedForInMember = true;
									default:
								}
							default:
						}
				default:
			}
		if (!retainedForInValue || !retainedForInMember)
			throw "for-in recovery discarded the typed map value or loop body";

		var recoveredCatchSource = new SourceFile("RecoveredCatchTyping.hx",
			"function main():Void { try { broken; } catch (error:Int) { error; } }");
		var recoveredCatchProgram = new Parser(new Lexer(recoveredCatchSource).tokenize()).parseProgramRecovering().program,
			recoveredCatchTyped = Typer.typeRecovered(recoveredCatchProgram);
		var retainedCatchType = false;
		if (recoveredCatchTyped != null && recoveredCatchTyped.functions.length == 1)
			switch recoveredCatchTyped.functions[0].statements[0] {
				case TTry(_, catches, _) if (catches.length == 1):
					switch catches[0].type {
						case TInt: retainedCatchType = true;
						default:
					}
				default:
			}
		if (!retainedCatchType)
			throw "try recovery discarded the declared catch type";

		var switchErrorSource = new SourceFile("SwitchErrorTyping.hx",
			"function main():Void { switch (broken) { case 1: var inside:Int = 1; default: var fallback:Int = 2; } var after:Int = 3; }");
		var switchErrorProgram = new Parser(new Lexer(switchErrorSource).tokenize()).parseProgramRecovering().program,
			switchErrorTyped = Typer.typeRecovered(switchErrorProgram);
		var retainedSwitchLocal = false;
		if (switchErrorTyped != null && switchErrorTyped.functions.length == 1)
			switch switchErrorTyped.functions[0].statements[0] {
				case TSwitch(subject, cases, defaultBranch, hasDefault, _):
					if (cases.length != 1 || !hasDefault)
						throw 'malformed switch recovery retained ${cases.length} cases and default=$hasDefault';
					switch subject.type {
						case TUnknown, TError:
						default:
							throw "malformed switch subject was not represented as a recovery type";
					}
					for (switchCase in cases)
						for (statement in switchCase.statements)
							switch statement {
								case TVar(_, _, _): retainedSwitchLocal = true;
								default:
							}
					for (statement in defaultBranch)
						switch statement {
							case TVar(_, _, _): retainedSwitchLocal = true;
							default:
						}
				default:
			}
		if (!retainedSwitchLocal)
			throw "tolerant typing discarded valid locals inside a malformed switch";

		var signatureService = new LanguageService(),
			signatureSource = "function take(value:Int):Void return; function main():Void return take(";
		signatureService.update("SignatureRecovery.hx", signatureSource);
		var signature = signatureService.signatureHelp("SignatureRecovery.hx", signatureSource.length);
		if (signature == null || signature.label != "take(value:Int):Void" || signature.activeParameter != 0)
			throw "recovered call did not expose signature help context";

		var interfaceService = new LanguageService(),
			interfaceSource = "class Foo {} interface Contract { function take(value:Foo):Void; } function main():Void { var contract:Contract; contract.take(";
		interfaceService.update("InterfaceRecovery.hx", interfaceSource);
		var interfaceSignature = interfaceService.signatureHelp("InterfaceRecovery.hx", interfaceSource.length);
		if (interfaceSignature == null || interfaceSignature.label != "take(value:Foo):Void" || interfaceSignature.activeParameter != 0)
			throw "recovered interface call did not expose signature help context";

		var navigationService = new LanguageService(),
			navigationSource = "function target():Void return; function main():Void return target(";
		navigationService.update("NavigationRecovery.hx", navigationSource);
		var targetDefinition = navigationService.definition("NavigationRecovery.hx", navigationSource.lastIndexOf("target(") + 1);
		var targetDeclaration = navigationSource.indexOf("target");
		if (targetDefinition == null || targetDefinition.span.start > targetDeclaration || targetDefinition.span.end < targetDeclaration)
			throw "recovered unfinished call did not resolve its current definition";
	}

	static function assertNestedRecovery(tail:String):Void {
		var service = new LanguageService(),
			source = 'function consume(value:Int):Int return value; function main():Int { var available:Int = 1; var values = [1]; $tail';
		service.update("Nested.hx", source);
		try
			service.analyze("Nested")
		catch (_:CompileError) {}
		var names = [for (item in service.complete("Nested.hx", source.length)) item.label];
		if (names.indexOf("available") < 0)
			throw 'nested recovery discarded its enclosing function for "$tail"';
		if (service.diagnostics("Nested.hx").length > 20)
			throw 'nested recovery exceeded its diagnostic budget for "$tail"';
	}

	static function assertTolerantTypedSnapshot():Void {
		var source = new SourceFile("Tolerant.hx", "function main():Void { var first:Int = 1; broken.unresolved().thing; var second:Int = first; }");
		var recovered = new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program,
			typed = Typer.typeRecovered(recovered);
		if (typed == null || typed.functions.length != 1)
			throw "tolerant typer did not produce a partial typed program";
		var functionBody = typed.functions[0].statements;
		if (functionBody.length != 3)
			throw 'tolerant typer discarded statements around an expression error: ${functionBody.length}';
		switch functionBody[2] {
			case TVar(name, _, _):
				if (name.indexOf(":second") < 0)
					throw 'tolerant typer retained the wrong local: $name';
			default:
				throw "tolerant typer did not retain the local after an expression error";
		}

		var expectedAssignmentSource = new SourceFile("TolerantExpectedAssignment.hx",
			"function main():Int { var value:Int = broken.unresolved(); return value; }");
		var expectedAssignmentProgram = new Parser(new Lexer(expectedAssignmentSource).tokenize()).parseProgramRecovering().program,
			expectedAssignmentTyped = Typer.typeRecovered(expectedAssignmentProgram);
		if (expectedAssignmentTyped == null || expectedAssignmentTyped.functions.length != 1)
			throw "tolerant typing discarded a declaration with a broken initializer";
		switch expectedAssignmentTyped.functions[0].statements[0] {
			case TVar(_, value, _) if (value.type == TInt):
			default:
			throw "tolerant coercion did not preserve the declared type after an initializer error";
		}

		var failedDeclarationSource = new SourceFile("TolerantFailedDeclaration.hx",
			"function main():Void { var broken = missing + 1; var after:Int = 1; }");
		var failedDeclarationProgram = new Parser(new Lexer(failedDeclarationSource).tokenize()).parseProgramRecovering().program,
			failedDeclarationTyped = Typer.typeRecovered(failedDeclarationProgram);
		if (failedDeclarationTyped == null || failedDeclarationTyped.functions.length != 1
			|| failedDeclarationTyped.functions[0].statements.length != 2)
			throw "tolerant typing discarded a declaration after an invalid initializer expression";
		switch failedDeclarationTyped.functions[0].statements[0] {
			case TVar(_, value, _) if (value.type == TUnknown || value.type == TError):
			default:
				throw "failed initializer did not retain a declaration-shaped recovery node";
		}

		var recoveredExpressionSource = new SourceFile("TolerantRecoveredExpressions.hx",
			"function main():Void { var arithmetic = missing + 1; var values = []; var typed:Array<Int> = [missing, 2]; var after:Int = 1; }");
		var recoveredExpressionProgram = new Parser(new Lexer(recoveredExpressionSource).tokenize()).parseProgramRecovering().program,
			recoveredExpressionTyped = Typer.typeRecovered(recoveredExpressionProgram);
		if (recoveredExpressionTyped == null || recoveredExpressionTyped.functions.length != 1
			|| recoveredExpressionTyped.functions[0].statements.length != 4)
			throw "tolerant expression recovery discarded declarations around malformed collection values";
		switch recoveredExpressionTyped.functions[0].statements[0] {
			case TVar(_, value, _):
				switch value.expression {
					case TAdd(_, _):
					default: throw "malformed arithmetic lost its recovered binary expression shape";
				}
			default: throw "malformed arithmetic did not remain a typed declaration";
		}
		switch recoveredExpressionTyped.functions[0].statements[1] {
			case TVar(_, value, _):
				switch value.type {
					case TArray(TUnknown):
					default: throw 'empty recovered array did not retain an unknown element type: ${value.type}';
				}
			default: throw "empty recovered array did not remain a typed declaration";
		}
		switch recoveredExpressionTyped.functions[0].statements[2] {
			case TVar(_, value, _):
				switch value.type {
					case TArray(TInt):
					default: throw 'invalid array element poisoned its known collection type: ${value.type}';
				}
			default: throw "invalid array element did not remain a typed declaration";
		}

		var inferredCollectionSource = new SourceFile("TolerantInferredCollections.hx",
			"class Item { public var member:Int; } function main():Void { var values = [missing, new Item()]; var lookup = [missing => null, 1 => new Item()]; var after:Int = 1; }");
		var inferredCollectionProgram = new Parser(new Lexer(inferredCollectionSource).tokenize()).parseProgramRecovering().program,
			inferredCollectionTyped = Typer.typeRecovered(inferredCollectionProgram),
			inferredCollectionMain = inferredCollectionTyped == null ? null : [for (fn in inferredCollectionTyped.functions) if (fn.name == "main") fn][0];
		if (inferredCollectionMain == null || inferredCollectionMain.statements.length != 3)
			throw "recovery discarded declarations around malformed inferred collections";
		switch inferredCollectionMain.statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TArray(TInstance(NominalKind.Class, "Item", _)):
					default: throw 'a malformed first array element prevented later type inference: ${value.type}';
				}
			default: throw "recovered inferred array did not remain a declaration";
		}
		switch inferredCollectionMain.statements[1] {
			case TVar(_, value, _):
				switch value.type {
					case TMap(TInt, TNullable(TInstance(NominalKind.Class, "Item", _))):
					default: throw 'malformed map entries did not refine key/value types: ${value.type}';
				}
			default: throw "recovered inferred map did not remain a declaration";
		}

		var astOnlySource = new SourceFile("TolerantAstOnlyIndex.hx",
			"function main(text:String):Void { var result = text.indexOf(; var conditional = missing ? 1 : 2; var after:Int = 1; }");
		var astOnlyProgram = new Parser(new Lexer(astOnlySource).tokenize()).parseProgramRecovering().program,
			astOnlyModel = new SemanticModel(astOnlyProgram, astOnlySource, 1);
		astOnlyModel.indexRecoveredSyntax(astOnlyProgram);
		astOnlyModel.freeze();
		var astOnlyContext = astOnlyModel.index.completionContext(astOnlySource.text.length),
			astOnlyResultType:Null<CompilerType> = null,
			astOnlyConditionalType:Null<CompilerType> = null;
		for (local in astOnlyContext.locals) {
			if (local.name == "result")
				astOnlyResultType = local.type;
			if (local.name == "conditional")
				astOnlyConditionalType = local.type;
		}
		switch astOnlyResultType {
			case TInt:
			default: throw 'AST-only recovery lost the built-in method result type: $astOnlyResultType';
		}
		switch astOnlyConditionalType {
			case TInt:
			default: throw 'AST-only recovery lost the conditional branch type: $astOnlyConditionalType';
		}

		var callSource = new SourceFile("TolerantCall.hx", "function take(value:Int):Void return; function main():Void return take(");
		var callProgram = new Parser(new Lexer(callSource).tokenize()).parseProgramRecovering().program,
			callTyped = Typer.typeRecovered(callProgram);
		if (callTyped == null || callTyped.functions.length != 2)
			throw "tolerant typer discarded an unfinished call";
		var callExpression = switch callTyped.functions[1].statements[0] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (callExpression == null || callExpression.type != TVoid)
			throw "unfinished call did not retain its resolved result type";
		switch callExpression.expression {
			case TCall(name, arguments) if (name == "take" && arguments.length == 1 && arguments[0].type == TInt):
			default:
				throw "unfinished call did not retain a typed callee";
		}

		var memberSource = new SourceFile("TolerantMember.hx",
			"class Foo { public function bar(value:Int):Int return value; } function main():Foo { var foo:Foo = new Foo(); return foo. }");
		var memberProgram = new Parser(new Lexer(memberSource).tokenize()).parseProgramRecovering().program,
			memberTyped = Typer.typeRecovered(memberProgram);
		if (memberTyped == null || memberTyped.functions.length != 2)
			throw "tolerant typer discarded an incomplete member expression";
		var memberExpression = switch memberTyped.functions[0].statements[1] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (memberExpression == null)
			throw "unfinished member access produced no typed expression";
		switch memberExpression.type {
			case TInstance(NominalKind.Class, "Foo", _):
			default:
				throw 'unfinished member access did not retain its receiver type: ${memberExpression.type}';
		}

		var knownMemberSource = new SourceFile("TolerantKnownMember.hx",
			"class Foo { public var known:Int; } function main():Void { var foo:Foo = new Foo(); var result = foo.missing().known; var after:Int = 1; }");
		var knownMemberProgram = new Parser(new Lexer(knownMemberSource).tokenize()).parseProgramRecovering().program,
			knownMemberTyped = Typer.typeRecovered(knownMemberProgram);
		if (knownMemberTyped == null || knownMemberTyped.functions.length != 1
			|| knownMemberTyped.functions[0].statements.length != 3)
			throw "an unresolved member chain discarded the surrounding declarations";
		var knownMemberExpression = switch knownMemberTyped.functions[0].statements[1] {
			case TVar(_, value, _): value;
			default: null;
		};
		if (knownMemberExpression == null)
			throw "an unresolved member chain did not remain a typed declaration";
		switch knownMemberExpression.expression {
			case TField(call, "known"):
				if (call.type != TUnknown)
					throw 'an unresolved member chain lost its unknown intermediate type: ${call.type}';
				switch call.expression {
					case TMethodCall(receiver, "missing", arguments):
						switch receiver.type {
							case TInstance(NominalKind.Class, "Foo", _) if (arguments.length == 0):
							default: throw "an unresolved member chain did not preserve its receiver type";
						}
					default:
						throw "an unresolved member chain did not preserve its receiver and call shape";
				}
			default:
				throw "an unresolved member chain collapsed its outer member expression";
		}

		var closureSource = new SourceFile("TolerantClosureCall.hx",
			"class Foo { public var known:Int; } function main():Void { var callback = missing; var result = callback().known; var after:Int = 1; }");
		var closureProgram = new Parser(new Lexer(closureSource).tokenize()).parseProgramRecovering().program,
			closureTyped = Typer.typeRecovered(closureProgram);
		if (closureTyped == null || closureTyped.functions.length != 1
			|| closureTyped.functions[0].statements.length != 3)
			throw "a non-callable closure expression discarded the surrounding declarations";
		var closureExpression = switch closureTyped.functions[0].statements[1] {
			case TVar(_, value, _): value;
			default: null;
		};
		if (closureExpression == null || closureExpression.type != TUnknown)
			throw 'a non-callable closure expression did not retain an unknown result: ${closureExpression == null ? "null" : Std.string(closureExpression.type)}';
		switch closureExpression.expression {
			case TField(call, "known"):
				switch call.expression {
					case TClosureCall(callee, arguments) if (callee.type == TError && arguments.length == 0):
					default: throw "a non-callable closure expression did not preserve its call shape";
				}
			default:
				throw "a non-callable closure expression collapsed its outer member expression";
		}

		var expectedClosureSource = new SourceFile("TolerantExpectedClosureCall.hx",
			"class Expected {} function main():Expected { var callback = missing; return callback(); var after:Int = 1; }");
		var expectedClosureProgram = new Parser(new Lexer(expectedClosureSource).tokenize()).parseProgramRecovering().program,
			expectedClosureTyped = Typer.typeRecovered(expectedClosureProgram),
			expectedClosureExpression:Null<TypedExpression> = null;
		if (expectedClosureTyped != null)
			for (fn in expectedClosureTyped.functions)
				if (fn.name == "main")
					for (statement in fn.statements)
						switch statement {
							case TReturn(expression, _): expectedClosureExpression = expression;
							default:
						}
		if (expectedClosureExpression == null)
			throw "an unresolved closure call with an expected result lost its return expression";
		switch expectedClosureExpression.type {
			case TInstance(NominalKind.Class, "Expected", _):
			default:
				throw 'an unresolved closure call did not preserve its expected result type: ${expectedClosureExpression.type}';
		}

		var expectedMethodSource = new SourceFile("TolerantExpectedMethodCall.hx",
			"class Expected {} function main():Expected { var value = missing; return value.unknown(); var after:Int = 1; }");
		var expectedMethodProgram = new Parser(new Lexer(expectedMethodSource).tokenize()).parseProgramRecovering().program,
			expectedMethodTyped = Typer.typeRecovered(expectedMethodProgram),
			expectedMethodExpression:Null<TypedExpression> = null;
		if (expectedMethodTyped != null)
			for (fn in expectedMethodTyped.functions)
				if (fn.name == "main")
					for (statement in fn.statements)
						switch statement {
							case TReturn(expression, _): expectedMethodExpression = expression;
							default:
						}
		if (expectedMethodExpression == null)
			throw "an unresolved method call with an expected result lost its return expression";
		switch expectedMethodExpression.type {
			case TInstance(NominalKind.Class, "Expected", _):
			default:
				throw 'an unresolved method call did not preserve its expected result type: ${expectedMethodExpression.type}';
		}

		var implicitFieldCallSource = new SourceFile("TolerantImplicitFieldCall.hx",
			"class Holder { public var callback:Int; public function run():Void { callback(); var after:Int = 1; } } function main():Void return;");
		var implicitFieldCallProgram = new Parser(new Lexer(implicitFieldCallSource).tokenize()).parseProgramRecovering().program,
			implicitFieldCallTyped = Typer.typeRecovered(implicitFieldCallProgram),
			implicitFieldCallBody:Array<TypedStatement> = null;
		if (implicitFieldCallTyped != null)
			for (fn in implicitFieldCallTyped.functions)
				if (fn.name == "Holder.run")
					implicitFieldCallBody = fn.statements;
		if (implicitFieldCallBody == null || implicitFieldCallBody.length != 2)
			throw "a non-callable implicit field discarded the surrounding declaration";
		switch implicitFieldCallBody[0] {
			case TExpression(expression, _) if (expression.type == TUnknown):
			switch expression.expression {
					case TClosureCall(callee, arguments) if (callee.type == TInt && arguments.length == 0):
					default: throw "a non-callable implicit field did not preserve its call shape";
				}
			default:
				throw "a non-callable implicit field did not remain an expression statement";
		}

		var fieldAssignmentSource = new SourceFile("TolerantFieldAssignment.hx",
			"class Foo { public var known:Int; } function main():Void { var foo:Foo = new Foo(); foo.missing = 1; var after:Int = 1; }");
		var fieldAssignmentProgram = new Parser(new Lexer(fieldAssignmentSource).tokenize()).parseProgramRecovering().program,
			fieldAssignmentTyped = Typer.typeRecovered(fieldAssignmentProgram),
			fieldAssignmentBody:Array<TypedStatement> = null;
		if (fieldAssignmentTyped != null)
			for (fn in fieldAssignmentTyped.functions)
				if (fn.name == "main")
					fieldAssignmentBody = fn.statements;
		if (fieldAssignmentBody == null || fieldAssignmentBody.length != 3)
			throw "an invalid field assignment discarded the surrounding declaration";
		switch fieldAssignmentBody[1] {
			case TFieldAssign(object, "missing", value, _):
				switch object.type {
					case TInstance(NominalKind.Class, "Foo", _):
						if (value.type != TInt)
							throw "an invalid field assignment changed its value type";
					default: throw "an invalid field assignment changed its receiver type";
				}
			default: throw 'an invalid field assignment did not preserve its typed receiver and value: ${Std.string(fieldAssignmentBody[1])}';
		}

		var indexAssignmentSource = new SourceFile("TolerantIndexAssignment.hx",
			"class Foo {} function main():Void { var foo:Foo = new Foo(); foo[0] = 1; var after:Int = 1; }");
		var indexAssignmentProgram = new Parser(new Lexer(indexAssignmentSource).tokenize()).parseProgramRecovering().program,
			indexAssignmentTyped = Typer.typeRecovered(indexAssignmentProgram),
			indexAssignmentBody:Array<TypedStatement> = null;
		if (indexAssignmentTyped != null)
			for (fn in indexAssignmentTyped.functions)
				if (fn.name == "main")
					indexAssignmentBody = fn.statements;
		if (indexAssignmentBody == null || indexAssignmentBody.length != 3)
			throw "an invalid index assignment discarded the surrounding declaration";
		switch indexAssignmentBody[1] {
			case TIndexAssign(array, index, value, _) :
				switch array.type {
					case TInstance(NominalKind.Class, "Foo", _):
						if (index.type != TInt || value.type != TInt)
							throw "an invalid index assignment changed its typed index or value";
					default: throw "an invalid index assignment changed its receiver type";
				}
			default: throw 'an invalid index assignment did not preserve its typed shape: ${Std.string(indexAssignmentBody[1])}';
		}

		var postErrorService = new LanguageService(),
			postErrorSource = "class Foo { public var value:Int; } function main():Void { var foo:Foo = new Foo(); broken.unresolved().thing; foo. }";
		postErrorService.update("TolerantPostError.hx", postErrorSource);
		var postErrorNames = [
			for (item in postErrorService.complete("TolerantPostError.hx", postErrorSource.length))
				item.label
		];
		if (postErrorNames.indexOf("value") < 0)
			throw "an expression error erased the known local type needed for member completion";

		var iteratorService = new LanguageService(),
			iteratorSource = "class Item { public var member:Int; } function main(values:Iterator<Item>):Void { for (item in values) { item. } }",
			iteratorPosition = iteratorSource.indexOf("item. }") + "item.".length;
		iteratorService.update("IteratorRecovery.hx", iteratorSource);
		var iteratorNames = [for (item in iteratorService.complete("IteratorRecovery.hx", iteratorPosition)) item.label];
		if (iteratorNames.indexOf("member") < 0)
			throw "recovered iterator loop lost its element type for member completion";

		var lambdaService = new LanguageService(),
			lambdaSource = "class Foo { public var member:Int; } function main():Void { var callback:(value:Foo)->Void = (value) -> { var local:Foo = value; local. }; }";
		lambdaService.update("TolerantLambda.hx", lambdaSource);
		var lambdaPosition = lambdaSource.indexOf("local.") + "local.".length,
			lambdaContext = lambdaService.completionContext("TolerantLambda.hx", lambdaPosition),
			lambdaNames = [for (item in lambdaService.complete("TolerantLambda.hx", lambdaPosition)) item.label],
			hasLambdaValue = false,
			hasLambdaLocal = false;
		if (lambdaContext == null)
			throw "recovered lambda did not expose a completion context";
		for (local in lambdaContext.context.locals) {
			if (local.name == "value")
				hasLambdaValue = true;
			if (local.name == "local")
				hasLambdaLocal = true;
		}
		if (!hasLambdaValue || !hasLambdaLocal || lambdaNames.indexOf("member") < 0)
			throw 'recovered lambda scope lost its parameter or local: locals=${[for (local in lambdaContext.context.locals) local.name].join(",")}, items=${lambdaNames.join(",")}';

		var captureService = new LanguageService(),
			captureSource = "class CaptureFoo { public var member:Int; } function main():Void { var foo:CaptureFoo = new CaptureFoo(); var callback:(value:Int)->Void = (value) -> { var result:Int = value + foo.member; foo. }; }";
		captureService.update("TolerantCapture.hx", captureSource);
		var capturePosition = captureSource.indexOf("foo. }") + "foo.".length,
			captureContext = captureService.completionContext("TolerantCapture.hx", capturePosition),
			captureNames = [for (item in captureService.complete("TolerantCapture.hx", capturePosition)) item.label],
			hasCapturedFoo = false;
		if (captureContext == null)
			throw "recovered lambda capture did not expose a completion context";
		for (local in captureContext.context.locals)
			if (local.name == "foo")
				hasCapturedFoo = true;
		if (!hasCapturedFoo || captureNames.indexOf("member") < 0)
			throw 'recovered lambda scope lost its captured local: locals=${[for (local in captureContext.context.locals) local.name].join(",")}, items=${captureNames.join(",")}';

		var uncontextualLambdaSource = new SourceFile("TolerantUncontextualLambda.hx",
			"function main():Void { var callback = (value) -> value; var after:Int = 1; }");
		var uncontextualLambdaProgram = new Parser(new Lexer(uncontextualLambdaSource).tokenize()).parseProgramRecovering().program,
			uncontextualLambdaTyped = Typer.typeRecovered(uncontextualLambdaProgram),
			uncontextualLambdaMain = uncontextualLambdaTyped == null ? null : [for (fn in uncontextualLambdaTyped.functions) if (fn.name == "main") fn][0];
		if (uncontextualLambdaTyped == null || uncontextualLambdaMain == null || uncontextualLambdaMain.statements.length != 2)
			throw 'tolerant typing discarded a lambda without contextual parameter types: ${uncontextualLambdaTyped == null ? "null" : uncontextualLambdaTyped.functions.length + "/" + (uncontextualLambdaMain == null ? "no-main" : Std.string(uncontextualLambdaMain.statements.length))}';
		switch uncontextualLambdaMain.statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TFunction([TUnknown], TUnknown):
					default: throw 'uncontextual lambda did not retain unknown parameter/result types: ${value.type}';
				}
			default: throw "uncontextual lambda did not remain a declaration-shaped expression";
		}

		var assignmentInferenceSource = new SourceFile("TolerantAssignmentInference.hx",
			"class Foo { public var member:Int; } function main():Void { var item = missing; item = new Foo(); item. }");
		var assignmentInferenceProgram = new Parser(new Lexer(assignmentInferenceSource).tokenize()).parseProgramRecovering().program,
			assignmentInferenceTyped = Typer.typeRecovered(assignmentInferenceProgram),
			assignmentInferenceMain = assignmentInferenceTyped == null ? null : [for (fn in assignmentInferenceTyped.functions) if (fn.name == "main") fn][0];
		if (assignmentInferenceTyped == null || assignmentInferenceMain == null || assignmentInferenceMain.statements.length != 3)
			throw "tolerant typing discarded a local refined by a later assignment";
		switch assignmentInferenceMain.statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TInstance(NominalKind.Class, "Foo", _):
					default: throw 'assignment inference did not refine the initial unknown local: ${value.type}';
				}
			default: throw "assignment inference did not retain the local declaration";
		}
		var assignmentInferenceService = new LanguageService();
		assignmentInferenceService.update("TolerantAssignmentInference.hx", assignmentInferenceSource.text);
		var assignmentInferenceNames = [
			for (item in assignmentInferenceService.complete("TolerantAssignmentInference.hx", assignmentInferenceSource.text.length)) item.label
		];
		if (assignmentInferenceNames.indexOf("member") < 0)
			throw "recovered indexing did not expose members after assignment-based local inference";

		var genericExpectedService = new LanguageService(),
			genericExpectedSource = "function pair<T>(first:T, second:T):T return first; function main():Void return pair(1, ";
		genericExpectedService.update("TolerantGenericExpected.hx", genericExpectedSource);
		var genericExpectedContext = genericExpectedService.completionContext("TolerantGenericExpected.hx", genericExpectedSource.length);
		if (genericExpectedContext == null || genericExpectedContext.context.expected != TInt)
			throw 'recovered generic call did not infer the later argument type: ${genericExpectedContext == null ? "null" : Std.string(genericExpectedContext.context.expected)}';

		var genericResultSource = new SourceFile("TolerantGenericResult.hx",
			"class Box { public var member:Int; } function identity<T>(value:T):T return value; function main():Void { var box = identity(new Box()); box. }");
		var genericResultProgram = new Parser(new Lexer(genericResultSource).tokenize()).parseProgramRecovering().program,
			genericResultTyped = Typer.typeRecovered(genericResultProgram),
			genericResultMain = genericResultTyped == null ? null : [for (fn in genericResultTyped.functions) if (fn.name == "main") fn][0];
		if (genericResultTyped == null || genericResultMain == null || genericResultMain.statements.length != 2)
			throw "recovered generic call result discarded the following member access";
		switch genericResultMain.statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TInstance(NominalKind.Class, "Box", _):
					default: throw 'recovered generic call did not infer its result type: ${value.type}';
				}
			default: throw "recovered generic call did not retain the inferred local declaration";
		}
		var genericResultService = new LanguageService();
		genericResultService.update("TolerantGenericResult.hx", genericResultSource.text);
		var genericResultNames = [
			for (item in genericResultService.complete("TolerantGenericResult.hx", genericResultSource.text.length)) item.label
		];
		if (genericResultNames.indexOf("member") < 0)
			throw "recovered generic call result did not expose receiver members";
		var expectedResultService = new LanguageService(),
			expectedResultSource = "class Expected { public var member:Int; } function identity<T>(value:T):T return value; function main():Expected return identity(";
		expectedResultService.update("TolerantGenericExpectedResult.hx", expectedResultSource);
		var expectedResultContext = expectedResultService.completionContext("TolerantGenericExpectedResult.hx", expectedResultSource.length),
			expectedResultType = expectedResultContext == null ? null : expectedResultContext.context.expected;
		if (expectedResultContext == null || expectedResultContext.context.kind != SemanticCompletionContextKind.Argument)
			throw "recovered generic result call did not expose an argument completion context";
		switch expectedResultType {
			case TInstance(NominalKind.Class, "Expected", _):
			default: throw 'recovered generic result call lost its expected argument type: ${expectedResultType == null ? "null" : Std.string(expectedResultType)}';
		}

		var conditionalSource = new SourceFile("TolerantConditional.hx",
			"class Foo { public var value:Int; } function main():Void { var foo = broken ? new Foo() : new Foo(); foo. }");
		var conditionalProgram = new Parser(new Lexer(conditionalSource).tokenize()).parseProgramRecovering().program,
			conditionalTyped = Typer.typeRecovered(conditionalProgram);
		if (conditionalTyped == null || conditionalTyped.functions.length != 1)
			throw "tolerant typing discarded a conditional with an invalid predicate";
		switch conditionalTyped.functions[0].statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TInstance(NominalKind.Class, "Foo", _):
					default:
						throw 'invalid conditional predicate poisoned its known branch type: ${value.type}';
				}
			default:
				throw 'invalid conditional predicate poisoned its known branch type: ${conditionalTyped.functions[0].statements[0]}';
		}
		var conditionalService = new LanguageService(),
			conditionalEditorSource = "class Foo { public var value:Int; } function main():Void { var foo = broken ? new Foo() : new Foo(); foo. }";
		conditionalService.update("TolerantConditional.hx", conditionalEditorSource);
		var conditionalNames = [
			for (item in conditionalService.complete("TolerantConditional.hx", conditionalEditorSource.length))
				item.label
		];
		if (conditionalNames.indexOf("value") < 0)
			throw "recovered indexing discarded a partial typed local in favor of an unknown AST type";

		var compoundConditionalSource = new SourceFile("TolerantCompoundConditional.hx",
			"class Item { public var value:Int; } function main():Void { var items = broken ? [] : [new Item()]; }"),
			compoundConditionalProgram = new Parser(new Lexer(compoundConditionalSource).tokenize()).parseProgramRecovering().program,
			compoundConditionalTyped = Typer.typeRecovered(compoundConditionalProgram);
		if (compoundConditionalTyped == null || compoundConditionalTyped.functions.length != 1)
			throw "tolerant typing discarded a conditional with a nested recovery type";
		switch compoundConditionalTyped.functions[0].statements[0] {
			case TVar(_, value, _):
				switch value.type {
					case TArray(TInstance(NominalKind.Class, "Item", _)):
					default: throw 'nested conditional recovery poisoned its known branch type: ${value.type}';
				}
			default: throw "nested conditional recovery did not retain its declaration";
		}

		var compoundCoercionSource = new SourceFile("TolerantCompoundCoercion.hx",
			"class Item {} function take(items:Array<Item>):Void return; function main():Void { var items = []; take(items); }");
		var compoundCoercionProgram = new Parser(new Lexer(compoundCoercionSource).tokenize()).parseProgramRecovering().program,
			compoundCoercionTyped = Typer.typeRecovered(compoundCoercionProgram);
		if (compoundCoercionTyped == null || compoundCoercionTyped.functions.length != 2)
			throw "tolerant typing discarded a call with a nested recovery argument type";
		switch compoundCoercionTyped.functions[1].statements[1] {
			case TExpression(expression, _):
				switch expression.expression {
					case TCall(_, arguments) if (arguments.length == 1):
						switch arguments[0].type {
							case TArray(TInstance(NominalKind.Class, "Item", _)):
							default: throw 'nested recovery argument was not coerced to its expected type: ${arguments[0].type}';
						}
					default: throw "nested recovery call did not retain its argument";
				}
			default: throw "nested recovery call did not remain a typed expression";
		}

		var switchSource = new SourceFile("TolerantSwitch.hx",
			"function main():Int { var value = switch (broken) { case 1: 1; default: 2; }; return value; }");
		var switchProgram = new Parser(new Lexer(switchSource).tokenize()).parseProgramRecovering().program,
			switchTyped = Typer.typeRecovered(switchProgram);
		if (switchTyped == null || switchTyped.functions.length != 1)
			throw "tolerant typing discarded a switch with an invalid subject";
		switch switchTyped.functions[0].statements[0] {
			case TVar(_, value, _) if (value.type == TInt):
				switch value.expression {
					case TSwitchExpression(_, cases, defaultExpression) if (cases.length == 1 && defaultExpression != null):
					default:
						throw "invalid switch subject discarded its typed cases";
				}
		default:
			throw "invalid switch subject poisoned its known result type";
	}

	var recoveredPatternSource = new SourceFile("TolerantRecoveredPattern.hx",
		"class Payload { public var member:Int; } enum Choice<T> { Some(value:T); Empty; } function main(choice:Choice<Payload>):Void { switch (choice) { case Some(value): value.member; case Some(other): other.member; default: } }");
	var recoveredPatternProgram = new Parser(new Lexer(recoveredPatternSource).tokenize()).parseProgramRecovering().program,
		recoveredPatternTyped = Typer.typeRecovered(recoveredPatternProgram);
	var retainedRecoveredPattern = false;
	if (recoveredPatternTyped != null && recoveredPatternTyped.functions.length == 1)
		switch recoveredPatternTyped.functions[0].statements[0] {
			case TSwitch(_, cases, _, _, _) if (cases.length >= 1):
				for (statement in cases[0].statements)
					switch statement {
						case TExpression(expression, _):
							switch expression.expression {
								case TField(object, "member"):
									switch object.type {
									case TInstance(NominalKind.Class, "Payload", _): retainedRecoveredPattern = true;
									default:
								}
								default:
							}
						default:
					}
			default:
		}
		if (!retainedRecoveredPattern)
			throw "tolerant switch recovery discarded an enum payload binding";

		var recoveredSwitchExpressionSource = new SourceFile("TolerantRecoveredSwitchExpression.hx",
			"class Payload { public var member:Int; } function main():Void { var value = switch (1) { case 1: new Payload(); case 2: 0; }; value. }"),
			recoveredSwitchExpressionProgram = new Parser(new Lexer(recoveredSwitchExpressionSource).tokenize()).parseProgramRecovering().program,
			recoveredSwitchExpressionTyped = Typer.typeRecovered(recoveredSwitchExpressionProgram),
			retainedRecoveredSwitchExpression = false;
		if (recoveredSwitchExpressionTyped != null && recoveredSwitchExpressionTyped.functions.length == 1)
			switch recoveredSwitchExpressionTyped.functions[0].statements[0] {
				case TVar(_, value, _) if (value.type == TUnknown):
					switch value.expression {
						case TSwitchExpression(_, cases, _) if (cases.length == 2): retainedRecoveredSwitchExpression = true;
						default:
					}
				default:
			}
		if (!retainedRecoveredSwitchExpression)
			throw "incompatible recovered switch branches discarded the partial expression tree";

		var recoveredConditionalSource = new SourceFile("TolerantRecoveredConditional.hx",
			"class Payload { public var member:Int; } function main():Void { var value = broken ? new Payload() : 0; value. }"),
			recoveredConditionalProgram = new Parser(new Lexer(recoveredConditionalSource).tokenize()).parseProgramRecovering().program,
			recoveredConditionalTyped = Typer.typeRecovered(recoveredConditionalProgram),
			retainedRecoveredConditional = false;
		if (recoveredConditionalTyped != null && recoveredConditionalTyped.functions.length == 1)
			switch recoveredConditionalTyped.functions[0].statements[0] {
				case TVar(_, value, _) if (value.type == TUnknown):
					switch value.expression {
						case TConditional(_, _, _) : retainedRecoveredConditional = true;
						default:
					}
				default:
			}
		if (!retainedRecoveredConditional)
			throw "incompatible recovered conditional branches discarded the partial expression tree";

		var chainedErrorSource = new SourceFile("TolerantChainedError.hx",
			"function main():Void { var value = broken.unresolved().thing; var after:Int = 1; }");
		var chainedErrorProgram = new Parser(new Lexer(chainedErrorSource).tokenize()).parseProgramRecovering().program,
			chainedErrorTyped = Typer.typeRecovered(chainedErrorProgram);
		if (chainedErrorTyped == null || chainedErrorTyped.functions.length != 1)
			throw "tolerant typing discarded a chained unresolved expression";
		switch chainedErrorTyped.functions[0].statements[0] {
			case TVar(_, value, _):
				if (value.type != TUnknown)
					throw 'chained unresolved expression did not retain a local unknown type: ${value.type}';
			default:
				throw "chained unresolved expression did not remain a local declaration";
		}

		var methodSource = new SourceFile("TolerantMethodCall.hx",
			"class Foo { public function bar(value:Int):Int return value; } function main():Int { var foo:Foo = new Foo(); return foo.bar(");
		var methodProgram = new Parser(new Lexer(methodSource).tokenize()).parseProgramRecovering().program,
			methodTyped = Typer.typeRecovered(methodProgram);
		if (methodTyped == null || methodTyped.functions.length != 2)
			throw "tolerant typer discarded an unfinished method call";
		var methodExpression = switch methodTyped.functions[0].statements[1] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (methodExpression == null || methodExpression.type != TInt)
			throw "unfinished method call did not retain its resolved result type";

		var builtinMethodSource = new SourceFile("TolerantBuiltinMethods.hx",
			"function stringUse(value:String):Void { value.indexOf(; var afterString:Int = 1; }\n"
			+ "function arrayUse(values:Array<Int>):Void { values.push(; var afterArray:Int = 1; }\n"
			+ "function mapUse(values:Map<String,Int>):Void { values.get(; var afterMap:Int = 1; }");
		var builtinMethodProgram = new Parser(new Lexer(builtinMethodSource).tokenize()).parseProgramRecovering().program,
			builtinMethodTyped = Typer.typeRecovered(builtinMethodProgram);
		if (builtinMethodTyped == null || builtinMethodTyped.functions.length != 3)
			throw "tolerant typing discarded functions around incomplete built-in method calls";
		for (functionBody in [for (fn in builtinMethodTyped.functions) fn.statements])
			if (functionBody.length != 2)
				throw "an incomplete built-in method call discarded the following declaration";
		var stringCall = switch builtinMethodTyped.functions[0].statements[0] {
			case TExpression(expression, _): expression;
			default: null;
		};
		if (stringCall == null || stringCall.type != TInt)
			throw "incomplete String method call did not retain its known result type";
		var arrayCall = switch builtinMethodTyped.functions[1].statements[0] {
			case TExpression(expression, _): expression;
			default: null;
		};
		if (arrayCall == null || arrayCall.type != TInt)
			throw "incomplete Array method call did not retain its known result type";
		var mapCall = switch builtinMethodTyped.functions[2].statements[0] {
			case TExpression(expression, _): expression;
			default: null;
		};
		switch mapCall == null ? null : mapCall.type {
			case TNullable(TInt):
			default:
				throw "incomplete Map method call did not retain its nullable result type";
		}

		var genericAritySource = new SourceFile("TolerantGenericArity.hx",
			"function identity<T>(value:T):T return value; function main():Int return identity(1, 2);");
		var genericArityProgram = new Parser(new Lexer(genericAritySource).tokenize()).parseProgramRecovering().program,
			genericArityTyped = Typer.typeRecovered(genericArityProgram);
		var genericArityMain = -1;
		if (genericArityTyped != null)
			for (index in 0...genericArityTyped.functions.length)
				if (genericArityTyped.functions[index].name == "main")
					genericArityMain = index;
		if (genericArityTyped == null || genericArityMain < 0)
			throw 'tolerant typing discarded a generic call with an invalid argument count: ${genericArityTyped == null ? "null" : Std.string(genericArityTyped.functions.length)}';
		var genericArityExpression = switch genericArityTyped.functions[genericArityMain].statements[0] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (genericArityExpression == null || genericArityExpression.type != TInt)
			throw 'generic arity recovery poisoned the known result type: ${genericArityExpression == null ? "null" : Std.string(genericArityExpression.type)}';
		switch genericArityExpression.expression {
			case TCall(_, arguments) if (arguments.length == 2):
			default:
				throw "generic arity recovery discarded the typed call shape";
		}

		var closureAritySource = new SourceFile("TolerantClosureArity.hx",
			"function main():Void { var callback = (value:Int) -> value; callback(1, 2); var after:Int = 1; }");
		var closureArityProgram = new Parser(new Lexer(closureAritySource).tokenize()).parseProgramRecovering().program,
			closureArityTyped = Typer.typeRecovered(closureArityProgram);
		var closureArityMain = -1;
		if (closureArityTyped != null)
			for (index in 0...closureArityTyped.functions.length)
				if (closureArityTyped.functions[index].name == "main")
					closureArityMain = index;
		if (closureArityTyped == null || closureArityMain < 0
			|| closureArityTyped.functions[closureArityMain].statements.length != 3)
			throw 'tolerant typing discarded locals around an over-applied closure: ${closureArityTyped == null ? "null" : closureArityTyped.functions.length + "/" + closureArityTyped.functions[closureArityMain].statements.length}';

		var enumAritySource = new SourceFile("TolerantEnumArity.hx",
			"enum Choice { Item(value:Int); } function main():Void { Choice.Item(1, 2); var after:Int = 1; }");
		var enumArityProgram = new Parser(new Lexer(enumAritySource).tokenize()).parseProgramRecovering().program,
			enumArityTyped = Typer.typeRecovered(enumArityProgram);
		if (enumArityTyped == null || enumArityTyped.functions.length != 1
			|| enumArityTyped.functions[0].statements.length != 2)
			throw "tolerant typing discarded a declaration after an over-applied enum constructor";

		var fieldAritySource = new SourceFile("TolerantFunctionFieldArity.hx",
			"class Holder { public var callback:(value:Int)->Int; } function main():Void { var holder:Holder = new Holder(); holder.callback(1, 2); var after:Int = 1; }");
		var fieldArityProgram = new Parser(new Lexer(fieldAritySource).tokenize()).parseProgramRecovering().program,
			fieldArityTyped = Typer.typeRecovered(fieldArityProgram),
			fieldArityMain = -1;
		if (fieldArityTyped != null)
			for (index in 0...fieldArityTyped.functions.length)
				if (fieldArityTyped.functions[index].name == "main")
					fieldArityMain = index;
		if (fieldArityTyped == null || fieldArityMain < 0 || fieldArityTyped.functions[fieldArityMain].statements.length != 3)
			throw "tolerant typing discarded locals around an over-applied function field";
		switch fieldArityTyped.functions[fieldArityMain].statements[1] {
			case TExpression(expression, _) :
				switch expression.expression {
					case TClosureCall(_, arguments) if (arguments.length == 2):
					default:
						throw "over-applied function field did not retain its typed call shape";
				}
			default:
				throw "over-applied function field did not remain an expression statement";
		}

		var genericConstructorAritySource = new SourceFile("TolerantGenericConstructorArity.hx",
			"class Box<T> { public function new(value:T) {} } function main():Void { var box = new Box(1, 2); var after:Int = 1; }");
		var genericConstructorArityProgram = new Parser(new Lexer(genericConstructorAritySource).tokenize()).parseProgramRecovering().program,
			genericConstructorArityDiagnostics = [],
			genericConstructorArityTyped = Typer.typeRecovered(genericConstructorArityProgram, null, null, genericConstructorArityDiagnostics),
			genericConstructorArityMain = -1;
		if (genericConstructorArityTyped != null)
			for (index in 0...genericConstructorArityTyped.functions.length)
				if (genericConstructorArityTyped.functions[index].name == "main")
					genericConstructorArityMain = index;
		if (genericConstructorArityTyped == null || genericConstructorArityMain < 0
			|| genericConstructorArityTyped.functions[genericConstructorArityMain].statements.length != 2)
			throw "tolerant typing discarded locals around an over-applied generic constructor";
		switch genericConstructorArityTyped.functions[genericConstructorArityMain].statements[0] {
		case TVar(_, expression, _):
			if (expression.type == TUnknown || expression.type == TError)
				throw 'over-applied generic constructor lost its inferred result type: ${expression.type}; ${[for (diagnostic in genericConstructorArityDiagnostics) diagnostic.message].join("; ")}';
				switch expression.expression {
					case TNew(_, arguments, _) if (arguments.length == 2):
					default:
						throw "over-applied generic constructor did not retain its typed call shape";
				}
			default:
			throw 'over-applied generic constructor lost its inferred result type: ${genericConstructorArityTyped.functions[genericConstructorArityMain].statements[0]}; ${[for (diagnostic in genericConstructorArityDiagnostics) diagnostic.message].join("; ")}';
		}

		var constructorSource = new SourceFile("TolerantConstructor.hx", "class Box { public function new(value:Int) {} } function main():Box return new Box(");
		var constructorProgram = new Parser(new Lexer(constructorSource).tokenize()).parseProgramRecovering().program,
			constructorTyped = Typer.typeRecovered(constructorProgram);
		if (constructorTyped == null || constructorTyped.functions.length != 2)
			throw "tolerant typer discarded an unfinished constructor call";
		var constructorExpression = switch constructorTyped.functions[0].statements[0] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (constructorExpression == null)
			throw "unfinished constructor call produced no typed expression";
		switch constructorExpression.type {
			case TInstance(NominalKind.Class, "Box", _):
			default:
				throw 'unfinished constructor call did not retain its result type: ${constructorExpression.type}';
		}

		var genericSource = new SourceFile("TolerantGeneric.hx", "class Box<T> { public function new(value:T) {} } function main():Box<Int> return new Box<");
		var genericResult = new Parser(new Lexer(genericSource).tokenize()).parseProgramRecovering(),
			genericProgram = genericResult.program,
			genericTyped = Typer.typeRecovered(genericProgram);
		if (genericTyped == null || genericTyped.functions.length != 2)
			throw 'tolerant typer discarded an unfinished generic construction: ${genericTyped == null ? "null" : [for (fn in genericTyped.functions) fn.name].join(",")}';
		var genericExpression = switch genericTyped.functions[0].statements[0] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (genericExpression == null)
			throw "unfinished generic construction produced no typed expression";
		switch genericExpression.type {
			case TInstance(NominalKind.Class, "Box", _):
			default:
				throw 'unfinished generic construction did not retain its nominal result: ${genericExpression.type}';
		}

		var genericExpectedSource = new SourceFile("TolerantGenericExpected.hx",
			"class ExpectedBox<T> {} function main():ExpectedBox<String> return new ExpectedBox<");
		var genericExpectedProgram = new Parser(new Lexer(genericExpectedSource).tokenize()).parseProgramRecovering().program,
			genericExpectedTyped = Typer.typeRecovered(genericExpectedProgram),
			genericExpectedExpression:Null<TypedExpression> = null;
		if (genericExpectedTyped != null)
			for (fn in genericExpectedTyped.functions)
				if (fn.name == "main")
					switch fn.statements[0] {
						case TReturn(expression, _): genericExpectedExpression = expression;
						default:
					}
		if (genericExpectedExpression == null)
			throw "an unfinished generic constructor lost its expected return expression";
		switch genericExpectedExpression.type {
			case TInstance(NominalKind.Class, "ExpectedBox", arguments) if (arguments.length == 1 && Std.string(arguments[0]) == "TString"):
			default:
				throw 'unfinished generic construction did not retain its expected type arguments: ${genericExpectedExpression.type}';
		}

		var genericResultSource = new SourceFile("TolerantGenericResult.hx",
			"class Expected {} function identity<T>(value:T):T return value; function main():Expected return identity(");
		var genericResultProgram = new Parser(new Lexer(genericResultSource).tokenize()).parseProgramRecovering().program,
			genericResultTyped = Typer.typeRecovered(genericResultProgram);
		if (genericResultTyped == null || genericResultTyped.functions.length != 2)
			throw "tolerant typer discarded a generic call whose result supplies the expected type";
		var genericResultExpression = switch genericResultTyped.functions[0].statements[0] {
			case TReturn(expression, _): expression;
			default: null;
		};
		if (genericResultExpression == null)
			throw "expected-result generic call produced no typed expression";
		switch genericResultExpression.type {
			case TInstance(NominalKind.Class, "Expected", _):
			default:
				throw 'expected-result generic call did not infer its result type: ${genericResultExpression.type}; function result ${genericResultTyped.functions[0].result}';
		}

		var incompleteParameter = new SourceFile("TolerantParameter.hx", "function main(value:)");
		var parameterProgram = new Parser(new Lexer(incompleteParameter).tokenize()).parseProgramRecovering().program,
			parameterTyped = Typer.typeRecovered(parameterProgram);
		if (parameterTyped == null || parameterTyped.functions.length != 1 || parameterTyped.functions[0].arguments.length != 1)
			throw "tolerant typer abandoned a function with an incomplete parameter type";
		switch parameterTyped.functions[0].arguments[0].type {
			case TUnknown:
			default:
				throw "incomplete parameter type did not become TUnknown";
		}

		var unsupportedSignatureSource = new SourceFile("TolerantUnsupportedSignature.hx",
			"function broken(value:Int32):Int32 return value; function usable(value:Int):Int return value;");
		var unsupportedSignatureProgram = new Parser(new Lexer(unsupportedSignatureSource).tokenize()).parseProgramRecovering().program,
			unsupportedSignatureTyped = Typer.typeRecovered(unsupportedSignatureProgram);
		if (unsupportedSignatureTyped == null
			|| unsupportedSignatureTyped.functions.length != 2
			|| unsupportedSignatureTyped.functions[1].name != "usable")
			throw "tolerant typing abandoned a valid function after an unsupported signature type";

		var unsupportedDeclarationSource = new SourceFile("TolerantUnsupportedDeclaration.hx",
			"interface Contract { function broken(value:Int32):Int32; function usable(value:Int):Int; } enum Choice { Broken(value:Int32); Usable; } function main():Void return;");
		var unsupportedDeclarationProgram = new Parser(new Lexer(unsupportedDeclarationSource).tokenize()).parseProgramRecovering().program,
			unsupportedDeclarationTyped = Typer.typeRecovered(unsupportedDeclarationProgram);
		if (unsupportedDeclarationTyped == null
			|| unsupportedDeclarationTyped.interfaces.length != 1
			|| unsupportedDeclarationTyped.interfaces[0].methods.length != 2
			|| unsupportedDeclarationTyped.enums.length != 1
			|| unsupportedDeclarationTyped.enums[0].cases.length != 2)
			throw "tolerant typing abandoned declarations after unsupported interface or enum layout types";

		var duplicateFieldSource = new SourceFile("TolerantDuplicateField.hx",
			"class Broken { var value:Int; var value:String; public function visible():Void return; } function main():Void return;");
		var duplicateFieldProgram = new Parser(new Lexer(duplicateFieldSource).tokenize()).parseProgramRecovering().program,
			duplicateFieldDiagnostics = [],
			duplicateFieldTyped = Typer.typeRecovered(duplicateFieldProgram, null, null, duplicateFieldDiagnostics);
		if (duplicateFieldTyped == null
			|| duplicateFieldTyped.classes.length != 1
			|| duplicateFieldTyped.classes[0].methods.length != 1
			|| duplicateFieldTyped.functions.length != 2)
			throw 'tolerant typing abandoned a class after a duplicate field: ${duplicateFieldTyped == null ? "null" : "classes=" + duplicateFieldTyped.classes.length + ", methods=" + (duplicateFieldTyped.classes.length == 0 ? 0 : duplicateFieldTyped.classes[0].methods.length) + ", functions=" + duplicateFieldTyped.functions.length}, diagnostics=${[for (diagnostic in duplicateFieldDiagnostics) diagnostic.message].join(" | ")}';
		var duplicateDeclarationSource = new SourceFile("TolerantDuplicateDeclaration.hx",
			"function same():Void return; function same():Void return; function usable():Void return;");
		var duplicateDeclarationProgram = new Parser(new Lexer(duplicateDeclarationSource).tokenize()).parseProgramRecovering().program,
			duplicateDeclarationDiagnostics = [],
			duplicateDeclarationTyped = Typer.typeRecovered(duplicateDeclarationProgram, null, null, duplicateDeclarationDiagnostics);
		if (duplicateDeclarationTyped == null
			|| duplicateDeclarationTyped.functions.length != 3
			|| duplicateDeclarationDiagnostics.length == 0)
			throw "tolerant typing did not report and retain duplicate top-level declarations";

		var invalidValueClassSource = new SourceFile("TolerantInvalidValueClass.hx",
			"class Base {} @:value class Broken extends Base {} class Usable { public function read():Void return; } function main():Void return;");
		var invalidValueClassProgram = new Parser(new Lexer(invalidValueClassSource).tokenize()).parseProgramRecovering().program,
			invalidValueClassTyped = Typer.typeRecovered(invalidValueClassProgram);
		if (invalidValueClassTyped == null
			|| invalidValueClassTyped.classes.length != 3
			|| invalidValueClassTyped.classes[2].name != "Usable")
			throw "tolerant typing abandoned a class after an invalid value-class relationship";

		var invalidNativeValueSource = new SourceFile("TolerantInvalidNativeValue.hx",
			"@:value @:repr(\"C\") class Broken {} class Usable { public function read():Void return; } function main():Void return;");
		var invalidNativeValueProgram = new Parser(new Lexer(invalidNativeValueSource).tokenize()).parseProgramRecovering().program,
			invalidNativeValueTyped = Typer.typeRecovered(invalidNativeValueProgram);
		if (invalidNativeValueTyped == null
			|| invalidNativeValueTyped.classes.length != 2
			|| invalidNativeValueTyped.classes[1].name != "Usable")
			throw "tolerant typing abandoned a program after an invalid native value layout";

		var invalidMetadataSource = new SourceFile("TolerantInvalidMetadata.hx",
			"@:repr(\"unsupported\") class Broken {} class Usable { public function read():Void return; } function main():Void return;");
		var invalidMetadataProgram = new Parser(new Lexer(invalidMetadataSource).tokenize()).parseProgramRecovering().program,
			invalidMetadataTyped = Typer.typeRecovered(invalidMetadataProgram);
		if (invalidMetadataTyped == null
			|| invalidMetadataTyped.classes.length != 2
			|| invalidMetadataTyped.classes[1].name != "Usable")
			throw "tolerant typing abandoned a program after invalid representation metadata";

		var invalidInlineSource = new SourceFile("TolerantInvalidInline.hx",
			"class Broken { public static inline var value:Int = unknown; public function visible():Void return; } function main():Void return;");
		var invalidInlineProgram = new Parser(new Lexer(invalidInlineSource).tokenize()).parseProgramRecovering().program,
			invalidInlineTyped = Typer.typeRecovered(invalidInlineProgram);
		if (invalidInlineTyped == null
			|| invalidInlineTyped.classes.length != 1
			|| invalidInlineTyped.classes[0].methods.length != 1)
			throw "tolerant typing abandoned a class after an invalid inline initializer";
	}

	static function assertTolerantDeclarationSnapshot():Void {
		var source = new SourceFile("TolerantDeclaration.hx", "class Child extends\nfunction main():Void return;");
		var recovered = new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program,
			typed = Typer.typeRecovered(recovered);
		if (recovered.classes.length != 1)
			throw 'parser did not retain the incomplete class: classes=${recovered.classes.length}, functions=${recovered.functions.length}';
		if (typed == null)
			throw "tolerant typing abandoned a program with an incomplete inheritance clause";
		if (typed.classes.length != 1 || typed.functions.length != 1 || typed.functions[0].name != "main")
			throw 'tolerant typing discarded a valid declaration: classes=${typed.classes.length}, functions=${typed.functions.length}';

		var interfaceSource = new SourceFile("TolerantInterfaceDeclaration.hx", "interface Contract extends\nfunction main():Void return;");
		var interfaceRecovered = new Parser(new Lexer(interfaceSource).tokenize()).parseProgramRecovering().program,
			interfaceTyped = Typer.typeRecovered(interfaceRecovered);
		if (interfaceRecovered.interfaces.length != 1
			|| interfaceTyped == null
			|| interfaceTyped.interfaces.length != 1
			|| interfaceTyped.functions.length != 1)
			throw "tolerant typing abandoned a program with an incomplete interface inheritance clause";

		var implementsSource = new SourceFile("TolerantImplementsDeclaration.hx", "class Child implements\nfunction main():Void return;");
		var implementsRecovered = new Parser(new Lexer(implementsSource).tokenize()).parseProgramRecovering().program,
			implementsTyped = Typer.typeRecovered(implementsRecovered);
		if (implementsRecovered.classes.length != 1
			|| implementsTyped == null
			|| implementsTyped.classes.length != 1
			|| implementsTyped.functions.length != 1)
			throw "tolerant typing abandoned a program with an incomplete implements clause";

		var fieldSource = new SourceFile("TolerantFieldDeclaration.hx",
			"class Broken { var field:MissingType; public function visible():Void return; } function main():Void return;");
		var fieldRecovered = new Parser(new Lexer(fieldSource).tokenize()).parseProgramRecovering().program,
			fieldTyped = Typer.typeRecovered(fieldRecovered);
		if (fieldTyped == null
			|| fieldTyped.classes.length != 1
			|| fieldTyped.classes[0].methods.length != 1
			|| fieldTyped.functions.length != 2)
			throw 'tolerant typing discarded class methods after an invalid field type: ${fieldTyped == null ? "null" : "classes=" + fieldTyped.classes.length + ", methods=" + (fieldTyped.classes.length == 0 ? 0 : fieldTyped.classes[0].methods.length) + ", functions=" + fieldTyped.functions.length}';
		switch fieldTyped.classes[0].fields[0].type {
			case TUnknown:
			default:
				throw 'invalid field type was not represented as TUnknown: ${fieldTyped.classes[0].fields[0].type}';
		}

		var initializerSource = new SourceFile("TolerantFieldInitializer.hx",
			"class Broken { var bad:Int = \"wrong\"; var good:String = \"ok\"; public function visible():Void return; } function main():Void return;");
		var initializerProgram = new Parser(new Lexer(initializerSource).tokenize()).parseProgramRecovering().program,
			initializerTyped = Typer.typeRecovered(initializerProgram);
		if (initializerTyped == null
			|| initializerTyped.classes.length != 1
			|| initializerTyped.classes[0].fields.length != 2
			|| initializerTyped.classes[0].methods.length != 2
			|| initializerTyped.functions.length != 3)
			throw "tolerant typing discarded fields or methods after an invalid field initializer";
		switch initializerTyped.classes[0].fields[0].initializer {
			case null:
				throw "invalid field initializer was discarded instead of becoming a typed error";
			case value if (value.type == TError):
			default:
				throw 'invalid field initializer did not become TError: ${initializerTyped.classes[0].fields[0].initializer}';
		}

		var invalidFieldTypeSource = new SourceFile("TolerantInvalidFieldType.hx",
			"class Broken { var invalid:Void; var valid:String; public function visible():Void return; } function main():Void return;");
		var invalidFieldTypeProgram = new Parser(new Lexer(invalidFieldTypeSource).tokenize()).parseProgramRecovering().program,
			invalidFieldTypeTyped = Typer.typeRecovered(invalidFieldTypeProgram);
		if (invalidFieldTypeTyped == null
			|| invalidFieldTypeTyped.classes.length != 1
			|| invalidFieldTypeTyped.classes[0].fields.length != 2
			|| invalidFieldTypeTyped.classes[0].methods.length != 1
			|| invalidFieldTypeTyped.functions.length != 2)
			throw "invalid field type discarded the rest of the recovered class";
		switch invalidFieldTypeTyped.classes[0].fields[0].type {
			case TError:
			default:
				throw 'invalid field type did not become TError: ${invalidFieldTypeTyped.classes[0].fields[0].type}';
		}

		var invalidInterfaceTypeSource = new SourceFile("TolerantInvalidInterfaceType.hx",
			"interface Broken { function invalid(value:Missing):Missing; function visible():Void; } function main():Void return;");
		var invalidInterfaceTypeProgram = new Parser(new Lexer(invalidInterfaceTypeSource).tokenize()).parseProgramRecovering().program,
			invalidInterfaceTypeTyped = Typer.typeRecovered(invalidInterfaceTypeProgram);
		if (invalidInterfaceTypeTyped == null
			|| invalidInterfaceTypeTyped.interfaces.length != 1
			|| invalidInterfaceTypeTyped.interfaces[0].methods.length != 2
			|| invalidInterfaceTypeTyped.functions.length != 1)
			throw "invalid interface types discarded the rest of the recovered interface";
		switch invalidInterfaceTypeTyped.interfaces[0].methods[0].arguments[0] {
			case TUnknown:
			default:
				throw 'invalid interface parameter did not become TUnknown: ${invalidInterfaceTypeTyped.interfaces[0].methods[0].arguments[0]}';
		}
		switch invalidInterfaceTypeTyped.interfaces[0].methods[0].result {
			case TUnknown:
			default:
				throw 'invalid interface result did not become TUnknown: ${invalidInterfaceTypeTyped.interfaces[0].methods[0].result}';
		}

		var invalidEnumTypeSource = new SourceFile("TolerantInvalidEnumType.hx",
			"enum Broken { invalid(value:Missing); visible; } function main():Void return;");
		var invalidEnumTypeProgram = new Parser(new Lexer(invalidEnumTypeSource).tokenize()).parseProgramRecovering().program,
			invalidEnumTypeTyped = Typer.typeRecovered(invalidEnumTypeProgram);
		if (invalidEnumTypeTyped == null
			|| invalidEnumTypeTyped.enums.length != 1
			|| invalidEnumTypeTyped.enums[0].cases.length != 2
			|| invalidEnumTypeTyped.functions.length != 1)
			throw "invalid enum payload type discarded the rest of the recovered enum";
		switch invalidEnumTypeTyped.enums[0].cases[0].params[0] {
			case TUnknown:
			default:
				throw 'invalid enum payload type did not become TUnknown: ${invalidEnumTypeTyped.enums[0].cases[0].params[0]}';
		}

		var diagnosticService = new LanguageService();
		diagnosticService.update("TolerantTypeDiagnostics.hx", "class Broken { var missing:Missing; } function main():Void return;");
		var foundSemanticTypeDiagnostic = false;
		for (diagnostic in diagnosticService.diagnostics("TolerantTypeDiagnostics.hx"))
			if (diagnostic.origin == DiagnosticOrigin.Semantic && StringTools.contains(diagnostic.message, "Unknown type"))
				foundSemanticTypeDiagnostic = true;
		if (!foundSemanticTypeDiagnostic)
			throw "recovered unknown type did not produce a semantic diagnostic";
	}

	static function assertRecoveryCancellation():Void {
		var source = new SourceFile("CancelledRecovery.hx", "function main():Void { var first:Int = 1; var second:Int = first; }");
		var token = new CancellationToken();
		token.cancel();
		var cancelled = false;
		try
			Typer.typeRecovered(new Parser(new Lexer(source).tokenize()).parseProgramRecovering().program, null, token.check)
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled)
			throw "partial typing swallowed a cancelled recovery request";

		var inferenceSource = new SourceFile("CancelledInference.hx", [for (index in 0...32)
			"function candidate" + index + "() return " + index + ";"].join("")),
			inferenceProgram = new Parser(new Lexer(inferenceSource).tokenize()).parseProgramRecovering().program,
			inferenceCheckpoints = 0;
		cancelled = false;
		try {
			SignatureInference.inferProgram(inferenceProgram, function() {
				inferenceCheckpoints++;
				if (inferenceCheckpoints == 6)
					throw new CancellationError();
			});
		}
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled || inferenceCheckpoints < 6)
			throw "signature inference did not honor its cancellation checkpoint";

		var checkpoints = 0;
		cancelled = false;
		try {
			new Parser(new Lexer(source).tokenize(), function() {
				if (++checkpoints == 2)
					throw new CancellationError();
			}).parseProgramRecovering();
		} catch (error:CancellationError)
			cancelled = true;
		if (!cancelled)
			throw "parser recovery did not honor its cancellation checkpoint";

		var service = new LanguageService();
		service.update("CancelledAnalysis.hx", "function main():Void { var value:");
		var state = service.compiler.modules.get("CancelledAnalysis"),
			beforeSnapshot = state == null ? null : state.currentRecovered,
			beforeDiagnostics = service.diagnostics("CancelledAnalysis.hx");
		if (state == null || beforeSnapshot == null || beforeDiagnostics.length == 0)
			throw "cancelled-analysis fixture did not publish its recovered snapshot";
		var analysisToken = new CancellationToken();
		analysisToken.cancel();
		cancelled = false;
		try
			service.analyze("CancelledAnalysis", analysisToken)
		catch (error:CancellationError)
			cancelled = true;
		var afterDiagnostics = service.diagnostics("CancelledAnalysis.hx");
		if (!cancelled
			|| state.currentRecovered != beforeSnapshot
			|| afterDiagnostics.length != beforeDiagnostics.length)
			throw "cancelled analysis published over the current recovered editor snapshot";

		var compileService = new LanguageService();
		compileService.update("CancelledCompile.hx", "function main():Int { var value:");
		var compileState = compileService.compiler.modules.get("CancelledCompile"),
			compileSnapshot = compileState == null ? null : compileState.currentRecovered,
			compileDiagnostics = compileService.diagnostics("CancelledCompile.hx"),
			compileToken = new CancellationToken();
		compileToken.cancel();
		cancelled = false;
		try
			compileService.compile("CancelledCompile", compileToken)
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled
			|| compileState == null
			|| compileState.currentRecovered != compileSnapshot
			|| compileService.diagnostics("CancelledCompile.hx").length != compileDiagnostics.length)
			throw "cancelled compilation published over the current recovered editor snapshot";
	}

	static function assertSupersededRecovery():Void {
		var state = new ModuleState("SupersededRecovery", new SourceFile("SupersededRecovery.hx", "function main():Void return;")),
			publishedDiagnostics = 0,
			engine = new RecoveryEngine({
				editorDefines: function() return [],
				typingModules: function(state, _, _) {
					state.update(new SourceFile("SupersededRecovery.hx", "function main():Void { var replacement:"));
					return [];
				},
				reuseFunctions: function(_, _, _, _) return [],
				resolveSymbol: function(_, _, _, _) return null,
				resolveTypeSymbol: function(_, _, _, _) return null,
				resolveEnumCase: function(_, _, _, _, _) return null,
				resolveType: function(_, _, _, _, _) return null,
				symbolCandidates: function(_, _, _, _) return [],
				publishDiagnostics: function(_, diagnostics) publishedDiagnostics += diagnostics.length
			});
		var result = engine.recover(state);
		if (result.published || publishedDiagnostics != 0 || state.currentRecovered != null)
			throw "superseded recovery published stale syntax or diagnostics";
	}

	static function assertTransactionSourceGeneration():Void {
		var compiler = new Compiler();
		compiler.update("TransactionGeneration.hx", "function main():Int return 1;");
		compiler.analyze("TransactionGeneration");
		var state = compiler.modules.get("TransactionGeneration");
		if (state == null || state.ast == null)
			throw "transaction generation fixture did not establish an exact snapshot";

		var nextSource = "function main():Int return 2;",
			analysisToken = new SourceSupersedingToken(compiler, "TransactionGeneration.hx", nextSource),
			cancelled = false;
		try
			compiler.analyze("TransactionGeneration", analysisToken)
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled
			|| state.source.text != nextSource
			|| state.ast != null
			|| state.semanticModel != null)
			throw "analysis published a candidate after its source generation was superseded";

		var compile = new Compiler();
		compile.update("CachedGeneration.hx", "function main():Int return 1;");
		compile.compile("CachedGeneration");
		var compileState = compile.modules.get("CachedGeneration"),
			compileSource = "function main():Int return 3;",
			compileToken = new SourceSupersedingToken(compile, "CachedGeneration.hx", compileSource);
		cancelled = false;
		try
			compile.compile("CachedGeneration", compileToken)
		catch (error:CancellationError)
			cancelled = true;
		if (!cancelled
			|| compileState == null
			|| compileState.source.text != compileSource
			|| compileState.ast != null
			|| compileState.semanticModel != null)
			throw "cached compilation returned a result after its source generation was superseded";
	}

	static function assertDiagnosticOrigins():Void {
		var parserService = new LanguageService();
		parserService.update("ParserDiagnostic.hx", "function main():Void { var value:");
		var parserDiagnostics = parserService.diagnostics("ParserDiagnostic.hx");
		if (parserDiagnostics.length == 0 || parserDiagnostics[0].origin != DiagnosticOrigin.ParserRecovery)
			throw "recovery diagnostics did not retain parser provenance";
		try
			parserService.analyze("ParserDiagnostic")
		catch (_:CompileError) {}
		parserDiagnostics = parserService.diagnostics("ParserDiagnostic.hx");
		if (parserDiagnostics.length == 0 || parserDiagnostics[0].origin != DiagnosticOrigin.ParserRecovery)
			throw 'background analysis obscured parser recovery provenance: ${[for (diagnostic in parserDiagnostics) diagnostic.message + "/" + Std.string(diagnostic.origin)].join(", ")}';

		var semanticService = new LanguageService();
		semanticService.update("SemanticDiagnostic.hx", "function main():Int return \"wrong\";");
		try
			semanticService.analyze("SemanticDiagnostic")
		catch (_:CompileError) {}
		var semanticDiagnostics = semanticService.diagnostics("SemanticDiagnostic.hx");
		if (semanticDiagnostics.length == 0 || semanticDiagnostics[0].origin != DiagnosticOrigin.Semantic)
			throw 'type diagnostics were relabeled as recovery: ${[for (diagnostic in semanticDiagnostics) diagnostic.message + "/" + Std.string(diagnostic.origin)].join(", ")}';

		var immediateSemanticService = new LanguageService();
		immediateSemanticService.update("ImmediateSemanticDiagnostic.hx", "function main():Void { var value:Int = \"wrong\"; }");
		var immediateSemanticDiagnostics = immediateSemanticService.diagnostics("ImmediateSemanticDiagnostic.hx");
		if (immediateSemanticDiagnostics.length == 0 || immediateSemanticDiagnostics[0].origin != DiagnosticOrigin.Semantic)
			throw 'localized recovery typing did not publish semantic provenance immediately: ${[for (diagnostic in immediateSemanticDiagnostics) diagnostic.message + "/" + Std.string(diagnostic.origin)].join(", ")}';

		var lexicalService = new LanguageService();
		lexicalService.update("LexicalDiagnostic.hx", "function main():Void return \"");
		var lexicalDiagnostics = lexicalService.diagnostics("LexicalDiagnostic.hx");
		if (lexicalDiagnostics.length != 1 || lexicalDiagnostics[0].origin != DiagnosticOrigin.Lexical)
			throw "lexical recovery diagnostics did not retain lexical provenance";
		try
			lexicalService.analyze("LexicalDiagnostic")
		catch (_:CompileError) {}
		lexicalDiagnostics = lexicalService.diagnostics("LexicalDiagnostic.hx");
		if (lexicalDiagnostics.length != 1 || lexicalDiagnostics[0].origin != DiagnosticOrigin.Lexical)
			throw "background analysis obscured lexical provenance";
	}

	static function assertTruncationRecovery():Void {
		var source = "package demo; class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function main():Int { var box:Box = new Box(); var values = [1, 2]; var read = (item:Int) -> item + box.value; return switch (values[0]) { case 1: read(41); default: 0; }; }";
		for (end in 0...source.length + 1) {
			var prefix = source.substring(0, end),
				file = new SourceFile("Truncated.hx", prefix);
			try {
				var recovered = new Parser(new Lexer(file).tokenize()).parseProgramRecovering();
				if (recovered.diagnostics.length > 20)
					throw 'recovery diagnostic budget exceeded at prefix $end';
			} catch (error:CompileError) {
				if (error.diagnostic.code != "E0001")
					throw 'recovering parser threw at prefix $end: ${error.diagnostic.message}';
			}
		}
		var errorFile = new SourceFile("ErrorNode.hx", "function main():Void { var incomplete ="),
			errorProgram = new Parser(new Lexer(errorFile).tokenize()).parseProgramRecovering().program;
		if (errorProgram.functions.length != 1)
			throw "error expression recovery discarded its function";
		switch errorProgram.functions[0].statements[0] {
			case VarDeclaration(_, _, ErrorExpression(_), _):
			default:
				throw "incomplete initializer did not produce an ErrorExpression";
		}
		var typeFile = new SourceFile("ErrorType.hx", "function main():Void { var incomplete:"),
			typeProgram = new Parser(new Lexer(typeFile).tokenize()).parseProgramRecovering().program;
		switch typeProgram.functions[0].statements[0] {
			case UninitializedDeclaration(_, ErrorType(_), _):
			default:
				throw "incomplete annotation did not produce an ErrorType";
		}
		var statementFile = new SourceFile("ErrorStatement.hx", "function main():Void { var = ; return; }"),
			statementProgram = new Parser(new Lexer(statementFile).tokenize()).parseProgramRecovering().program;
		switch statementProgram.functions[0].statements[0] {
			case VarDeclaration("<missing>", _, ErrorExpression(_), _):
			default:
				throw "malformed local declaration did not preserve a missing name and expression";
		}
	}

	static function assertTolerantTruncationTyping():Void {
		var source = "class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function helper(value:Int):Int return value; function main():Int { var box:Box = new Box(); var values = [1, 2]; return box.read(";
		for (end in 0...source.length + 1) {
			var file = new SourceFile("TolerantTruncated.hx", source.substring(0, end)),
				program = new Parser(new Lexer(file).tokenize()).parseProgramRecovering().program;
			if (Typer.typeRecovered(program) == null)
				throw 'tolerant typing abandoned ordinary prefix $end';
		}
	}
}

class SourceSupersedingToken extends CancellationToken {
	final compiler:Compiler;
	final path:String;
	final source:String;
	var first = true;

	public function new(compiler:Compiler, path:String, source:String) {
		super();
		this.compiler = compiler;
		this.path = path;
		this.source = source;
	}

	public override function check():Void {
		if (first) {
			first = false;
			compiler.update(path, source);
		}
		super.check();
	}
}
