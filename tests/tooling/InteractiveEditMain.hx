import compiler.Source.SourceSpan;
import compiler.service.CancellationToken;
import compiler.service.LanguageService;
import compiler.service.LanguageService.TextEdit;

typedef RecoveryProbe = {
	final validMarker:String;
	final validOffset:Int;
	final malformedMarker:String;
	final malformedOffset:Int;
}

typedef RecoveryCase = {
	final name:String;
	final path:String;
	final module:String;
	final valid:String;
	final malformed:String;
	final probes:Array<RecoveryProbe>;
	final symbols:Array<String>;
}

/** Exercises the language service as a sequence of real editor updates. */
class InteractiveEditMain {
	static function main():Void {
		var service = new LanguageService(),
			prefix = "class Foo { public function bar(value:Int):Int return value; }\n" + "function main():Void { var foo:Foo = new Foo(); ", tails = [
				"f",
				"fo",
				"foo",
				"foo.",
				"foo.b",
				"foo.ba",
				"foo.bar(",
				"foo.bar(x",
				"foo.bar(x)"
			];

		for (tail in tails) {
			var source = prefix + tail, position = source.length;
			service.update("Interactive.hx", source);
			assertHealthySnapshot(service, source, tail);

			var completion = service.completeResult("Interactive.hx", position);
			if (tail == "f" || tail == "fo" || tail == "foo")
				assertContains(completion.items, "foo", tail);
			if (tail == "foo." || tail == "foo.b" || tail == "foo.ba")
				assertContains(completion.items, "bar", tail);
			if (tail == "foo.bar(" || tail == "foo.bar(x") {
				var signature = service.signatureHelp("Interactive.hx", position);
				if (signature == null || signature.label != "bar(value:Int):Int" || signature.activeParameter != 0)
					throw 'signature help was lost during interactive edit "$tail"';
			}
			if (tail == "foo.bar(x)" && !completion.isIncomplete)
				throw "recovery snapshot unexpectedly became exact without a complete statement";
		}

		var malformed = prefix + "broken.unresolved().member; var after:Foo = foo.";
		service.update("Interactive.hx", malformed);
		assertHealthySnapshot(service, malformed, "malformed statement");
		var malformedSymbols = service.documentSymbols("Interactive.hx");
		if (malformedSymbols.length < 3)
			throw 'malformed statement removed the enclosing function or class symbols: ${[for (symbol in malformedSymbols) symbol.name].join(", ")}';
		assertContains(service.completeResult("Interactive.hx", malformed.length).items, "bar", "after error");

		var diagnostics = service.diagnostics("Interactive.hx"),
			seen:Map<String, Bool> = [];
		for (diagnostic in diagnostics) {
			var key = diagnostic.span.start + ":" + diagnostic.message;
			if (seen.exists(key))
				throw "interactive edit produced duplicate diagnostics";
			seen.set(key, true);
		}

		var boundaryCases:Array<{prefix:String, tails:Array<String>, symbols:Array<String>}> = [
			{
				prefix: "class Foo { public function existing():Void {} }\n",
				tails: ["function test(a:Int,", "class Child extends"],
				symbols: ["Foo", "existing"]
			},
			{
				prefix: "class Foo {}\nfunction main():Void { ",
				tails: [
					"var value:",
					"var value:Foo = new Foo(",
					"if (true) {",
					"new Foo(",
					"var values:Array<Int> = ["
				],
				symbols: ["Foo", "main"]
			}
		];
		for (testCase in boundaryCases)
			for (tail in testCase.tails) {
				var source = testCase.prefix + tail;
				service.update("Interactive.hx", source);
				assertHealthySnapshot(service, source, tail);
				for (name in testCase.symbols)
					assertSymbol(service.documentSymbols("Interactive.hx"), name, tail);
				if (!service.completeResult("Interactive.hx", source.length).isIncomplete)
					throw 'boundary edit "$tail" was not marked as incomplete';
			}

		assertRecoveryEquivalence();
		assertCompoundRecoveryEquivalence();
		assertRecoveryMatrix();
		assertIdentityResolutionClosure();
		assertNavigationClosure();
		assertRenameClosure();
		assertLifecycleStress();

		Sys.println('PASS: ${tails.length + 15} interactive edits retained recovery queries');
	}

	static function assertRecoveryMatrix():Void {
		var cases:Array<RecoveryCase> = [
			{
				name: "unrelated expression errors",
				path: "matrix/RecoveryBody.hx",
				module: "matrix.RecoveryBody",
				valid: "package matrix; class Box { public var member:Int; } function main():Void { var before:Box = new Box(); before.member; var after:Box = before; after.member; }",
				malformed: "package matrix; class Box { public var member:Int; } function main():Void { var before:Box = new Box(); before.member; broken.unresolved().thing; another.unresolved().thing; var after:Box = before; after.member; }",
				probes: [
					{validMarker: "before:Box", validOffset: 0, malformedMarker: "before:Box", malformedOffset: 0},
					{validMarker: "before.member", validOffset: 0, malformedMarker: "before.member", malformedOffset: 0},
					{validMarker: "after:Box", validOffset: 0, malformedMarker: "after:Box", malformedOffset: 0},
					{validMarker: "after.member", validOffset: 0, malformedMarker: "after.member", malformedOffset: 0}
				],
				symbols: ["Box", "main"]
			},
			{
				name: "unfinished call",
				path: "matrix/RecoveryCall.hx",
				module: "matrix.RecoveryCall",
				valid: "package matrix; class CallBox { public function value(argument:Int):Int return argument; } function main():Void { var box:CallBox = new CallBox(); var before:Int = box.value(1); box.value(1); var after:Int = before; }",
				malformed: "package matrix; class CallBox { public function value(argument:Int):Int return argument; } function main():Void { var box:CallBox = new CallBox(); var before:Int = box.value(1); box.value( ; var after:Int = before; }",
				probes: [
					{validMarker: "box:CallBox", validOffset: 0, malformedMarker: "box:CallBox", malformedOffset: 0},
					{validMarker: "before:Int", validOffset: 0, malformedMarker: "before:Int", malformedOffset: 0},
					{validMarker: "after:Int", validOffset: 0, malformedMarker: "after:Int", malformedOffset: 0}
				],
				symbols: ["CallBox", "main"]
			},
			{
				name: "unfinished generic type",
				path: "matrix/RecoveryGeneric.hx",
				module: "matrix.RecoveryGeneric",
				valid: "package matrix; class GenericBox<T> { public var value:T; } function main():Void { var before:Int = 1; var box:GenericBox<Int> = new GenericBox<Int>(); var after:Int = box.value; }",
				malformed: "package matrix; class GenericBox<T> { public var value:T; } function main():Void { var before:Int = 1; var box:GenericBox<Int = new GenericBox<Int>(); var after:Int = box.value; }",
				probes: [
					{validMarker: "before:Int", validOffset: 0, malformedMarker: "before:Int", malformedOffset: 0},
					{validMarker: "after:Int", validOffset: 0, malformedMarker: "after:Int", malformedOffset: 0},
					{validMarker: "box.value", validOffset: 0, malformedMarker: "box.value", malformedOffset: 0}
				],
				symbols: ["GenericBox", "main"]
			},
			{
				name: "unfinished declaration",
				path: "matrix/RecoveryDeclaration.hx",
				module: "matrix.RecoveryDeclaration",
				valid: "package matrix; class Holder { public function before():Int return 1; public function after():Int return 2; } function main():Void {}",
				malformed: "package matrix; class Holder { public function before():Int return 1; public function unfinished(argument:Int { return 2; } public function after():Int return 3; } function main():Void {}",
				probes: [
					{validMarker: "before():Int", validOffset: 0, malformedMarker: "before():Int", malformedOffset: 0},
					{validMarker: "after():Int", validOffset: 0, malformedMarker: "after():Int", malformedOffset: 0}
				],
				symbols: ["Holder", "before", "after", "main"]
			},
			{
				name: "declaration families",
				path: "matrix/RecoveryDeclarations.hx",
				module: "matrix.RecoveryDeclarations",
				valid: "package matrix; typedef Alias<T> = Array<T>; interface Contract<T> { function get(value:T):T; } enum State { Idle; Ready(value:Int); } enum abstract Code(Int) from Int to Int { var Ok = 0; } abstract Wrapper<T>(T) { public function new(value:T) { this = value; } public function get():T return this; } function use(value:Alias<Int>):Alias<Int> return value; function main():Void { var before:Int = 1; var after:Int = before; return; }",
				malformed: "package matrix; typedef Alias<T> = Array<T>; interface Contract<T> { function get(value:T):T; } enum State { Idle; Ready(value:Int); } enum abstract Code(Int) from Int to Int { var Ok = 0; } abstract Wrapper<T>(T) { public function new(value:T) { this = value; } public function get():T return this; } function use(value:Alias<Int>):Alias<Int> return value; function main():Void { var before:Int = 1; broken.unresolved().thing; var after:Int = before; return; }",
				probes: [
					{validMarker: "Alias", validOffset: 1, malformedMarker: "Alias", malformedOffset: 1},
					{validMarker: "Contract", validOffset: 1, malformedMarker: "Contract", malformedOffset: 1},
					{validMarker: "State", validOffset: 1, malformedMarker: "State", malformedOffset: 1},
					{validMarker: "Ready", validOffset: 1, malformedMarker: "Ready", malformedOffset: 1},
					{validMarker: "Code", validOffset: 1, malformedMarker: "Code", malformedOffset: 1},
					{validMarker: "Ok", validOffset: 1, malformedMarker: "Ok", malformedOffset: 1},
					{validMarker: "Wrapper", validOffset: 1, malformedMarker: "Wrapper", malformedOffset: 1},
					{validMarker: "before", validOffset: 1, malformedMarker: "before", malformedOffset: 1},
					{validMarker: "after", validOffset: 1, malformedMarker: "after", malformedOffset: 1}
				],
				symbols: ["Alias", "Contract", "State", "Code", "Wrapper", "use", "main"]
			}
		];

		for (testCase in cases) {
			var service = new LanguageService();
			service.update(testCase.path, testCase.valid);
			service.analyze(testCase.module);
			var validState = service.compiler.modules.get(testCase.module),
				validModel = validState == null ? null : validState.semanticModel;
			if (validModel == null)
				throw 'recovery matrix case "${testCase.name}" did not produce an exact semantic model';
			assertRecoverySnapshot(service, testCase.path, testCase.valid, '${testCase.name} valid');

			var validIds:Array<String> = [];
			for (probe in testCase.probes) {
				var validPosition = markerPosition(testCase.valid, probe.validMarker, probe.validOffset),
					validId = validModel.index.symbolIdAt(validPosition);
				if (validId == null)
					throw 'recovery matrix case "${testCase.name}" could not index valid probe "${probe.validMarker}"';
				validIds.push(Std.string(validId));
			}

			service.update(testCase.path, testCase.malformed);
			var malformedState = service.compiler.modules.get(testCase.module),
				recoveredModel = malformedState == null ? null : malformedState.recoveredSemanticModel;
			if (malformedState == null || malformedState.currentRecovered == null || recoveredModel == null
				|| malformedState.diagnostics.length == 0
				|| malformedState.currentRecovered.source != malformedState.source
				|| malformedState.currentRecovered.revision != malformedState.revision)
				throw 'recovery matrix case "${testCase.name}" did not publish a coherent current-source snapshot';
			assertRecoverySnapshot(service, testCase.path, testCase.malformed, '${testCase.name} malformed');

			for (symbol in testCase.symbols)
				assertSymbol(service.documentSymbols(testCase.path), symbol, testCase.name);
			for (index in 0...testCase.probes.length) {
				var probe = testCase.probes[index],
					malformedPosition = markerPosition(testCase.malformed, probe.malformedMarker, probe.malformedOffset),
					recoveredId = recoveredModel.index.symbolIdAt(malformedPosition);
				if (recoveredId == null || Std.string(recoveredId) != validIds[index])
					throw 'recovery matrix case "${testCase.name}" changed unaffected identity at "${probe.malformedMarker}" (expected ${validIds[index]}, got ${recoveredId == null ? "null" : Std.string(recoveredId)})';
			}

			service.update(testCase.path, testCase.valid);
			service.analyze(testCase.module);
			var repairedState = service.compiler.modules.get(testCase.module),
				repairedModel = repairedState == null ? null : repairedState.semanticModel;
			if (repairedState == null || repairedState.currentExact == null || repairedModel == null)
				throw 'recovery matrix case "${testCase.name}" did not repair to an exact semantic model';
			assertRecoverySnapshot(service, testCase.path, testCase.valid, '${testCase.name} repaired');
			for (index in 0...testCase.probes.length) {
				var probe = testCase.probes[index],
					repairedPosition = markerPosition(testCase.valid, probe.validMarker, probe.validOffset),
					repairedId = repairedModel.index.symbolIdAt(repairedPosition);
				if (repairedId == null || Std.string(repairedId) != validIds[index])
					throw 'recovery matrix case "${testCase.name}" did not restore identity at "${probe.validMarker}"';
			}
		}
	}

	static function markerPosition(source:String, marker:String, offset:Int):Int {
		var position = source.indexOf(marker);
		if (position < 0)
			throw 'recovery matrix could not locate marker "$marker"';
		return position + offset;
	}

	static function assertRecoverySnapshot(service:LanguageService, path:String, source:String, label:String):Void {
		for (symbol in service.documentSymbols(path))
			assertSpan(symbol.span, source.length, 'recovery $label symbol', label);
		for (diagnostic in service.diagnostics(path))
			assertSpan(diagnostic.span, source.length, 'recovery $label diagnostic', label);
		for (token in service.semanticTokens(path))
			assertSpan(token.span, source.length, 'recovery $label semantic token', label);
		for (fold in service.foldingRanges(path))
			assertSpan(fold.span, source.length, 'recovery $label fold', label);
	}

	static function assertIdentityResolutionClosure():Void {
		var service = new LanguageService(),
			targetPath = "identity/types/Box.hx",
			consumerPath = "identity/app/Main.hx",
			target = "package identity.types; class Box { public var member:Int; } function main():Void return;",
			consumer = "package identity.app; import identity.types.Box as Alias; function main():Void { var box:Alias = new Alias(); box.member; }";
		service.update(targetPath, target);
		service.compile("identity.types.Box");
		service.update(consumerPath, consumer);
		service.compile("identity.app.Main");

		var targetMemberPosition = target.indexOf("member") + 1,
			consumerTypePosition = consumer.indexOf(":Alias") + 2,
			consumerMemberPosition = consumer.lastIndexOf("member") + 1,
			exactTargetDefinition = service.definition(targetPath, targetMemberPosition),
			exactTypeDefinition = service.typeDefinition(consumerPath, consumerTypePosition),
			exactMemberDefinition = service.definition(consumerPath, consumerMemberPosition),
			exactMemberId = service.compiler.modules.get("identity.app.Main").semanticModel.index.symbolIdAt(consumerMemberPosition);
		if (exactTargetDefinition == null || exactTypeDefinition == null || exactMemberDefinition == null
			|| exactTargetDefinition.path != targetPath
			|| exactTypeDefinition.path != targetPath
			|| exactMemberDefinition.path != targetPath
			|| exactMemberId == null)
			throw 'identity closure fixture did not establish exact imported aliases: target=${exactTargetDefinition == null ? "null" : exactTargetDefinition.path}, type=${exactTypeDefinition == null ? "null" : exactTypeDefinition.path}, member=${exactMemberDefinition == null ? "null" : exactMemberDefinition.path}, memberId=${exactMemberId == null ? "null" : Std.string(exactMemberId)}';

		var brokenTarget = "package identity.types; class Box { public var member:Int; function unfinished(",
			brokenConsumer = "package identity.app; import identity.types.Box as Alias; function main():Void { var box:Alias = new Alias(); broken.unresolved().thing; box.member; function unfinished(";
		service.update(targetPath, brokenTarget);
		service.update(consumerPath, brokenConsumer);

		var recoveredConsumerState = service.compiler.modules.get("identity.app.Main"),
			recoveredModel = recoveredConsumerState == null ? null : recoveredConsumerState.recoveredSemanticModel,
			recoveredTypePosition = brokenConsumer.indexOf(":Alias") + 2,
			recoveredMemberPosition = brokenConsumer.lastIndexOf("member") + 1,
			recoveredMemberId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(recoveredMemberPosition),
			recoveredTypeDefinition = service.typeDefinition(consumerPath, recoveredTypePosition),
			recoveredMemberDefinition = service.definition(consumerPath, recoveredMemberPosition),
			recoveredReferences = service.references(consumerPath, recoveredMemberPosition);
		if (recoveredConsumerState == null || recoveredModel == null
			|| recoveredMemberId == null
			|| Std.string(recoveredMemberId) != Std.string(exactMemberId)
			|| recoveredTypeDefinition == null || recoveredTypeDefinition.stale || recoveredTypeDefinition.path != targetPath
			|| recoveredMemberDefinition == null || recoveredMemberDefinition.stale || recoveredMemberDefinition.path != targetPath)
			throw 'recovered imported identity was not authoritative: type=${recoveredTypeDefinition == null ? "null" : recoveredTypeDefinition.path}, member=${recoveredMemberDefinition == null ? "null" : recoveredMemberDefinition.path}, references=${recoveredReferences.length}';

		var currentConsumerReference = false;
		for (reference in recoveredReferences)
			if (reference.path == consumerPath && !reference.stale)
				currentConsumerReference = true;
		if (!currentConsumerReference)
			throw "recovered imported identity did not retain a current consumer reference";

		service.update(targetPath, target);
		service.update(consumerPath, consumer);
		service.compile("identity.app.Main");
		var repairedState = service.compiler.modules.get("identity.app.Main"),
			repairedModel = repairedState == null ? null : repairedState.semanticModel,
			repairedMemberId = repairedModel == null ? null : repairedModel.index.symbolIdAt(consumerMemberPosition);
		if (repairedState == null || repairedModel == null
			|| repairedMemberId == null
			|| Std.string(repairedMemberId) != Std.string(exactMemberId))
			throw "repair did not restore imported type and member identities";
	}

	static function assertNavigationClosure():Void {
		var service = new LanguageService(),
			basePath = "navigation/base/Base.hx",
			childPath = "navigation/child/Child.hx",
			consumerPath = "navigation/app/Main.hx",
			base = "package navigation.base; class Base { public var seed:Int; public function new(seed:Int) { this.seed = seed; } public function run():Int return seed; } function main():Void return;",
			child = "package navigation.child; import navigation.base.Base; class Child extends Base { public function new(seed:Int) { super(seed); } public function run():Int return 1; } function main():Void return;",
			consumer = "package navigation.app; import navigation.child.Child; function main():Void { var child:Child = new Child(1); child.run(); }";
		service.update(basePath, base);
		service.compile("navigation.base.Base");
		service.update(childPath, child);
		service.update(consumerPath, consumer);
		service.compile("navigation.app.Main");

		var baseRunPosition = base.indexOf("run():Int") + 1,
			childRunPosition = child.indexOf("run():Int") + 1,
			consumerTypePosition = consumer.indexOf(":Child") + 2,
			consumerConstructorPosition = consumer.indexOf("new Child") + "new ".length + 1,
			consumerMemberPosition = consumer.lastIndexOf("run()") + 1,
			baseDefinition = service.definition(basePath, baseRunPosition),
			childDefinition = service.definition(childPath, childRunPosition),
			consumerTypeDefinition = service.typeDefinition(consumerPath, consumerTypePosition),
			constructorDefinition = service.definition(consumerPath, consumerConstructorPosition),
			childImplementations = service.implementations(basePath, baseRunPosition),
			baseReferences = service.references(basePath, baseRunPosition),
			childReferences = service.references(childPath, childRunPosition);
		if (baseDefinition == null || baseDefinition.path != basePath
			|| childDefinition == null || childDefinition.path != childPath
			|| consumerTypeDefinition == null || consumerTypeDefinition.path != childPath
			|| constructorDefinition == null || constructorDefinition.path != childPath)
			throw 'navigation closure disagreed on declaration identities: base=${baseDefinition == null ? "null" : baseDefinition.path}, child=${childDefinition == null ? "null" : childDefinition.path}, type=${consumerTypeDefinition == null ? "null" : consumerTypeDefinition.path}, constructor=${constructorDefinition == null ? "null" : constructorDefinition.path}';

		var foundChildImplementation = false,
			foundBaseDeclaration = false,
			foundChildDeclaration = false,
			foundConsumerUse = false;
		for (implementation in childImplementations)
			if (implementation.path == childPath)
				foundChildImplementation = true;
		for (reference in baseReferences) {
			if (reference.path == basePath && reference.span.start <= baseRunPosition && baseRunPosition < reference.span.end)
				foundBaseDeclaration = true;
			if (reference.path == consumerPath && reference.span.start <= consumerMemberPosition && consumerMemberPosition < reference.span.end)
				foundConsumerUse = true;
		}
		for (reference in childReferences)
			if (reference.path == childPath && reference.span.start <= childRunPosition && childRunPosition < reference.span.end)
				foundChildDeclaration = true;
		if (!foundChildImplementation || !foundBaseDeclaration || !foundChildDeclaration || !foundConsumerUse)
			throw 'navigation closure lost a shared member family: implementation=$foundChildImplementation, base=$foundBaseDeclaration, child=$foundChildDeclaration, consumer=$foundConsumerUse, baseReferences=${baseReferences.length}, childReferences=${childReferences.length}';

		var recoveredChild = "package navigation.child; import navigation.base.Base; class Child extends Base { public function new(seed:Int) { super(seed); } public function run():Int return super.run(); } function unfinished(";
		service.update(childPath, recoveredChild);
		var superRunPosition = recoveredChild.lastIndexOf("super.run") + "super.".length + 1,
			recoveredSuperDefinition = service.definition(childPath, superRunPosition),
			recoveredBaseReferences = service.references(basePath, baseRunPosition),
			foundSuperUse = false;
		for (reference in recoveredBaseReferences)
			if (reference.path == childPath && reference.span.start <= superRunPosition && superRunPosition < reference.span.end)
				foundSuperUse = true;
		if (recoveredSuperDefinition == null || recoveredSuperDefinition.path != basePath || !foundSuperUse)
			throw 'recovered super navigation disagreed with the base identity: definition=${recoveredSuperDefinition == null ? "null" : recoveredSuperDefinition.path}, references=${recoveredBaseReferences.length}';

		service.update("navigation/unrelated/Broken.hx", "package navigation.unrelated; class Broken { public function unfinished(");
		var afterNeighborReferences = service.references(basePath, baseRunPosition),
			retainedConsumerUse = false,
			retainedSuperUse = false;
		for (reference in afterNeighborReferences) {
			if (reference.path == consumerPath && !reference.stale)
				retainedConsumerUse = true;
			if (reference.path == childPath && reference.span.start <= superRunPosition && superRunPosition < reference.span.end)
				retainedSuperUse = true;
		}
		if (!retainedConsumerUse || !retainedSuperUse)
			throw 'malformed neighboring module disrupted authoritative navigation: references=${afterNeighborReferences.length}';
	}

	static function assertRenameClosure():Void {
		var service = new LanguageService(),
			targetPath = "rename/types/Box.hx",
			consumerPath = "rename/app/Main.hx",
			target = "package rename.types; class Box<T> { public var value:T; public function get(argument:T):T return argument; } enum Result { Ok; Err; } function main():Void return;",
			consumer = "package rename.app; import rename.types.Box; import rename.types.Box.Result; function main():Void { var box:Box<Int> = new Box<Int>(); box.value; box.get(1); var result:Result = Result.Ok; }";
		service.update(targetPath, target);
		service.compile("rename.types.Box");
		service.update(consumerPath, consumer);
		service.compile("rename.app.Main");

		var typeEdits = service.rename(targetPath, target.indexOf("class Box") + "class ".length + 1, "Container"),
			memberEdits = service.rename(targetPath, target.indexOf("value") + 1, "result"),
			genericEdits = service.rename(targetPath, target.indexOf("<T>") + 1, "Value"),
			localEdits = service.rename(consumerPath, consumer.indexOf("var box") + "var ".length + 1, "item"),
			enumEdits = service.rename(targetPath, target.indexOf("Ok") + 1, "Success"),
			enumCollision = service.rename(targetPath, target.indexOf("Ok") + 1, "Err");
		assertRenameEdits(typeEdits, "Container", 2, targetPath, consumerPath, "cross-module type");
		assertRenameEdits(memberEdits, "result", 2, targetPath, consumerPath, "cross-module member");
		assertRenameEdits(genericEdits, "Value", 3, targetPath, targetPath, "generic parameter");
		assertRenameEdits(localEdits, "item", 3, consumerPath, consumerPath, "local variable");
		assertRenameEdits(enumEdits, "Success", 2, targetPath, consumerPath, "enum case");
		if (enumCollision.length != 0)
			throw "rename allowed an enum-case collision";

		var malformedConsumer = "package rename.app; import rename.types.Box; import rename.types.Box.Result; function main():Void { var box:Box<Int> = new Box<Int>(); broken.unresolved().thing; box.value; function unfinished(";
		service.update(consumerPath, malformedConsumer);
		var malformedValuePosition = malformedConsumer.lastIndexOf("value") + 1,
			malformedRename = service.rename(targetPath, target.indexOf("value") + 1, "result"),
			malformedPrepare = service.prepareRename(consumerPath, malformedValuePosition);
		if (malformedRename.length != 0 || malformedPrepare != null)
			throw "rename crossed into a malformed consumer snapshot";

		service.update(consumerPath, consumer);
		service.compile("rename.app.Main");
		var repairedMemberEdits = service.rename(targetPath, target.indexOf("value") + 1, "result");
		assertRenameEdits(repairedMemberEdits, "result", 2, targetPath, consumerPath, "repaired cross-module member");
	}

	static function assertRenameEdits(edits:Array<TextEdit>, replacement:String, minimum:Int,
		firstPath:String, secondPath:String, label:String):Void {
		if (edits.length < minimum)
			throw 'rename closure produced too few edits for $label: ${edits.length}';
		var foundFirst = false,
			foundSecond = false;
		for (edit in edits) {
			if (edit.replacement != replacement || edit.stale)
				throw 'rename closure produced an unsafe edit for $label';
			if (edit.path == firstPath)
				foundFirst = true;
			if (edit.path == secondPath)
				foundSecond = true;
		}
		if (!foundFirst || !foundSecond)
			throw 'rename closure omitted an affected file for $label: first=$foundFirst, second=$foundSecond';
	}

	static function assertLifecycleStress():Void {
		var rapidService = new LanguageService(),
			rapidPath = "lifecycle/rapid/Main.hx",
			rapidModule = "lifecycle.rapid.Main",
			rapidValid = "package lifecycle.rapid; class Box { public var member:Int; } function main():Int { var box:Box = new Box(); return box.member; }",
			rapidMalformed = "package lifecycle.rapid; class Box { public var member:Int; } function main():Int { var box:Box = new Box(); return box.;",
			rapidRepaired = "package lifecycle.rapid; class Box { public var member:Int; } function main():Int { var box:Box = new Box(); return box.member + 1; }",
			lastRevision = 0;

		for (source in [rapidValid, rapidMalformed, rapidRepaired, rapidMalformed, rapidValid]) {
			var state = rapidService.update(rapidPath, source);
			if (state.revision <= lastRevision)
				throw 'rapid edit sequence did not advance revisions: previous=$lastRevision current=${state.revision}';
			lastRevision = state.revision;
			assertSnapshotCoherent(state, "rapid edit");
			if (state.currentExact != null)
				throw "editor update exposed an exact snapshot before analysis completed";
			if (state.currentRecovered == null
				|| state.currentRecovered.source != state.source
				|| state.currentRecovered.revision != state.revision)
				throw "rapid editor update did not publish a current recovered snapshot";
			if (source == rapidMalformed) {
				if (state.lastGood == null || state.lastGood.revision >= state.revision)
					throw "malformed edit lost or replaced the last-good snapshot";
				continue;
			}

			rapidService.analyze(rapidModule);
			state = rapidService.compiler.modules.get(rapidModule);
			if (state == null || state.currentExact == null
				|| state.currentExact.source != state.source
				|| state.currentExact.revision != state.revision)
				throw "repaired edit did not publish a coherent exact snapshot";
			assertSnapshotCoherent(state, "repaired rapid edit");
		}

		var service = new LanguageService(),
			basePath = "lifecycle/core/Base.hx",
			childPath = "lifecycle/core/Child.hx",
			consumerPath = "lifecycle/app/Main.hx",
			baseV1 = "package lifecycle.core; class Base { public var member:Int; public function new() {} public function value():Int return 1; } function main():Void return;",
			baseBodyEdit = "package lifecycle.core; class Base { public var member:Int; public function new() {} public function value():Int return 2; } function main():Void return;",
			baseSignatureEdit = "package lifecycle.core; class Base { public var member:Int; public function new() {} public function value():String return \"changed\"; } function main():Void return;",
			baseShapeEdit = "package lifecycle.core; class Base { public function new() {} public function value():Int return 3; } function main():Void return;",
			child = "package lifecycle.core; import lifecycle.core.Base; class Child extends Base { public function new() { super(); } } function main():Void return;",
			consumer = "package lifecycle.app; import lifecycle.core.Child; function main():Int { var value:Child = new Child(); var inherited:Int = value.member; return value.value() + inherited; }";

		service.update(basePath, baseV1);
		service.update(childPath, child);
		service.update(consumerPath, consumer);
		service.compile("lifecycle.app.Main");
		var baselineConsumer = service.compiler.modules.get("lifecycle.app.Main"),
			baselineSnapshot = baselineConsumer == null ? null : baselineConsumer.currentExact,
			memberPosition = consumer.indexOf("value.member") + "value.".length,
			baselineDefinition = service.definition(consumerPath, memberPosition);
		if (baselineConsumer == null || baselineSnapshot == null || baselineSnapshot.semanticModel == null
			|| baselineDefinition == null || baselineDefinition.path != basePath)
			throw "lifecycle fixture did not establish an exact inherited dependency snapshot";
		assertSnapshotCoherent(baselineConsumer, "lifecycle baseline consumer");

		service.update(basePath, baseBodyEdit);
		var bodyAnalysis = service.analyze("lifecycle.app.Main"),
			bodyConsumer = service.compiler.modules.get("lifecycle.app.Main"),
			bodyDefinition = service.definition(consumerPath, memberPosition);
		if (bodyConsumer == null
			|| bodyConsumer.currentExact == null
			|| baselineSnapshot == null
			|| bodyConsumer.currentExact.semanticModel == null
			|| baselineSnapshot.semanticModel == null
			|| bodyConsumer.currentExact.semanticModel.index != baselineSnapshot.semanticModel.index
			|| bodyAnalysis.invalidatedModules.indexOf("lifecycle.app.Main") >= 0
			|| bodyDefinition == null || bodyDefinition.path != basePath)
			throw 'body-only dependency edit rebuilt or disconnected the consumer: invalidated=${bodyAnalysis.invalidatedModules.join(",")}, retyped=${bodyAnalysis.retyped.join(",")}, definition=${bodyDefinition == null ? "null" : bodyDefinition.path}';
		assertSnapshotCoherent(bodyConsumer, "body-only consumer");
		var stableConsumerSnapshot = bodyConsumer.currentExact;

		service.update(basePath, baseSignatureEdit);
		var signatureFailed = false;
		try {
			service.analyze("lifecycle.app.Main");
		} catch (_:compiler.Diagnostic.CompileError) {
			signatureFailed = true;
		}
		if (!signatureFailed)
			throw "signature edit unexpectedly published a type-correct consumer";
		var signatureConsumer = service.compiler.modules.get("lifecycle.app.Main");
		if (signatureConsumer == null)
			throw "signature edit removed the consumer module";
		assertSnapshotCoherent(signatureConsumer, "failed signature edit consumer");
		if (signatureConsumer.currentExact != stableConsumerSnapshot)
			throw "failed signature analysis replaced the consumer exact snapshot";

		service.update(basePath, baseShapeEdit);
		var shapeFailed = false;
		var shapeAnalysis:Null<compiler.Compiler.AnalysisResult> = null;
		try {
			shapeAnalysis = service.analyze("lifecycle.app.Main");
		} catch (_:compiler.Diagnostic.CompileError) {
			shapeFailed = true;
		}
		if (!shapeFailed)
			throw 'base-shape edit unexpectedly retained a removed inherited member: invalidated=${shapeAnalysis == null ? "null" : shapeAnalysis.invalidatedModules.join(",")}, retyped=${shapeAnalysis == null ? "null" : shapeAnalysis.retyped.join(",")}';
		var shapeConsumer = service.compiler.modules.get("lifecycle.app.Main");
		if (shapeConsumer == null)
			throw "base-shape edit removed the consumer module";
		assertSnapshotCoherent(shapeConsumer, "failed base-shape edit consumer");
		if (shapeConsumer.currentExact != stableConsumerSnapshot)
			throw "failed base-shape analysis replaced the consumer exact snapshot";

		service.update(basePath, baseV1);
		service.analyze("lifecycle.app.Main");
		var repairedBase = service.compiler.modules.get("lifecycle.core.Base"),
			repairedChild = service.compiler.modules.get("lifecycle.core.Child"),
			repairedConsumer = service.compiler.modules.get("lifecycle.app.Main");
		if (repairedBase == null || repairedChild == null || repairedConsumer == null
			|| repairedBase.currentExact == null || repairedChild.currentExact == null
			|| repairedConsumer.currentExact == null)
			throw "repair after dependency invalidation did not republish all exact snapshots";
		assertSnapshotCoherent(repairedBase, "repaired base");
		assertSnapshotCoherent(repairedChild, "repaired child");
		assertSnapshotCoherent(repairedConsumer, "repaired consumer");
		var repairedDefinition = service.definition(consumerPath, memberPosition);
		if (repairedDefinition == null || repairedDefinition.path != basePath)
			throw "repair after dependency invalidation did not restore inherited navigation";

		var beforeCancellation = repairedConsumer.currentExact,
			cancelled = new CancellationToken();
		cancelled.cancel();
		var analysisCancelled = false;
		try {
			service.analyze("lifecycle.app.Main", cancelled);
		} catch (_:compiler.service.CancellationError) {
			analysisCancelled = true;
		}
		if (!analysisCancelled)
			throw "cancelled analysis unexpectedly completed";
		var afterAnalysisCancellation = service.compiler.modules.get("lifecycle.app.Main");
		if (afterAnalysisCancellation == null || afterAnalysisCancellation.currentExact != beforeCancellation)
			throw "cancelled analysis published a replacement snapshot";
		assertSnapshotCoherent(afterAnalysisCancellation, "cancelled analysis");

		var renameCancelled = false;
		try {
			service.rename(consumerPath, memberPosition, "renamed", cancelled);
		} catch (_:compiler.service.CancellationError) {
			renameCancelled = true;
		}
		if (!renameCancelled)
			throw "cancelled rename unexpectedly completed";
		var afterRenameCancellation = service.compiler.modules.get("lifecycle.app.Main");
		if (afterRenameCancellation == null || afterRenameCancellation.currentExact != beforeCancellation)
			throw "cancelled rename changed the published snapshot";
		assertSnapshotCoherent(afterRenameCancellation, "cancelled rename");
	}

	static function assertSnapshotCoherent(state:compiler.modules.ModuleState, label:String):Void {
		for (snapshot in [state.currentExact, state.currentRecovered, state.lastGood]) {
			if (snapshot == null)
				continue;
			if (snapshot.semanticModel != null
				&& (snapshot.semanticModel.source != snapshot.source
					|| snapshot.semanticModel.revision != snapshot.revision))
				throw '$label published a mixed source/model revision';
			if (snapshot.kind == compiler.modules.AnalysisSnapshot.AnalysisSnapshotKind.Exact
				&& snapshot.stale)
				throw '$label marked an exact snapshot stale';
			if (snapshot.kind == compiler.modules.AnalysisSnapshot.AnalysisSnapshotKind.Recovered
				&& !snapshot.recovered)
				throw '$label marked a recovered snapshot as exact';
		}
	}

	static function assertCompoundRecoveryEquivalence():Void {
		var switchService = new LanguageService(),
			switchValid = "class SwitchBox { public var member:Int; } enum Choice { Ready(value:SwitchBox); Empty; } function main():Void { var choice:Choice = Choice.Ready(new SwitchBox()); switch (choice) { case Ready(value): value.member; case Empty: } }";
		switchService.update("CompoundRecovery.hx", switchValid);
		switchService.compile("CompoundRecovery");
		var switchValidState = switchService.compiler.modules.get("CompoundRecovery"),
			switchBindingPosition = switchValid.indexOf("Ready(value)") + "Ready(".length + 1,
			switchBindingUsePosition = switchValid.indexOf("value.member") + 1,
			switchValidBindingId = switchValidState.semanticModel.index.symbolIdAt(switchBindingPosition),
			switchValidBindingUseId = switchValidState.semanticModel.index.symbolIdAt(switchBindingUsePosition);
		if (switchValidBindingId == null || switchValidBindingUseId == null
			|| Std.string(switchValidBindingId) != Std.string(switchValidBindingUseId))
			throw "switch recovery fixture did not establish a payload binding identity";

		var switchMalformed = "class SwitchBox { public var member:Int; } enum Choice { Ready(value:SwitchBox); Empty; } function main():Void { var choice:Choice = Choice.Ready(new SwitchBox()); switch (choice) { case Ready(value): broken.unresolved().thing; value.member; case Empty: } }";
		switchService.update("CompoundRecovery.hx", switchMalformed);
		var switchPosition = switchMalformed.indexOf("value.member") + "value.".length,
			switchCompletion = switchService.completeResult("CompoundRecovery.hx", switchPosition),
			foundSwitchMember = false;
		for (item in switchCompletion.items)
			if (item.label == "member" && item.detail == "member:Int")
				foundSwitchMember = true;
		var switchRecoveredState = switchService.compiler.modules.get("CompoundRecovery"),
			switchRecoveredModel = switchRecoveredState.recoveredSemanticModel,
			switchRecoveredBindingId = switchRecoveredModel == null ? null : switchRecoveredModel.index.symbolIdAt(switchMalformed.indexOf("Ready(value)") + "Ready(".length + 1),
			switchRecoveredBindingUseId = switchRecoveredModel == null ? null : switchRecoveredModel.index.symbolIdAt(switchMalformed.indexOf("value.member") + 1);
		if (!foundSwitchMember || !switchCompletion.isIncomplete
			|| switchRecoveredModel == null || switchRecoveredBindingId == null || switchRecoveredBindingUseId == null
			|| Std.string(switchRecoveredBindingId) != Std.string(switchRecoveredBindingUseId))
			throw "malformed switch recovery lost the payload scope or current member completion";

		switchService.update("CompoundRecovery.hx", switchValid);
		switchService.compile("CompoundRecovery");
		var switchRepairedState = switchService.compiler.modules.get("CompoundRecovery"),
			switchRepairedBindingId = switchRepairedState.semanticModel.index.symbolIdAt(switchBindingPosition);
		if (switchRepairedBindingId == null || Std.string(switchRepairedBindingId) != Std.string(switchValidBindingId)
			|| switchService.completeResult("CompoundRecovery.hx", switchValid.length).isIncomplete)
			throw "repair did not restore the exact switch payload identity";

		var tryService = new LanguageService(),
			tryValid = "class CatchBox { public var member:Int; } function main():Void { try { var value:CatchBox = new CatchBox(); value.member; } catch (error:CatchBox) { error.member; } }";
		tryService.update("TryCompoundRecovery.hx", tryValid);
		tryService.compile("TryCompoundRecovery");
		var tryValidState = tryService.compiler.modules.get("TryCompoundRecovery"),
			tryBindingPosition = tryValid.indexOf("catch (error:") + "catch (".length + 1,
			tryBindingUsePosition = tryValid.indexOf("error.member") + 1,
			tryValidBindingId = tryValidState.semanticModel.index.symbolIdAt(tryBindingPosition),
			tryValidBindingUseId = tryValidState.semanticModel.index.symbolIdAt(tryBindingUsePosition);
		if (tryValidBindingId == null || tryValidBindingUseId == null
			|| Std.string(tryValidBindingId) != Std.string(tryValidBindingUseId))
			throw "try/catch recovery fixture did not establish a catch binding identity";

		var tryMalformed = "class CatchBox { public var member:Int; } function main():Void { try { broken.unresolved().thing; } catch (error:CatchBox) { error.member; } }";
		tryService.update("TryCompoundRecovery.hx", tryMalformed);
		var tryPosition = tryMalformed.indexOf("error.member") + "error.".length,
			tryCompletion = tryService.completeResult("TryCompoundRecovery.hx", tryPosition),
			foundTryMember = false;
		for (item in tryCompletion.items)
			if (item.label == "member" && item.detail == "member:Int")
				foundTryMember = true;
		var tryRecoveredState = tryService.compiler.modules.get("TryCompoundRecovery"),
			tryRecoveredModel = tryRecoveredState.recoveredSemanticModel,
			tryRecoveredBindingId = tryRecoveredModel == null ? null : tryRecoveredModel.index.symbolIdAt(tryMalformed.indexOf("catch (error:") + "catch (".length + 1),
			tryRecoveredBindingUseId = tryRecoveredModel == null ? null : tryRecoveredModel.index.symbolIdAt(tryMalformed.indexOf("error.member") + 1);
		if (!foundTryMember || !tryCompletion.isIncomplete
			|| tryRecoveredModel == null || tryRecoveredBindingId == null || tryRecoveredBindingUseId == null
			|| Std.string(tryRecoveredBindingId) != Std.string(tryRecoveredBindingUseId))
			throw "malformed try/catch recovery lost the catch scope or current member completion";

		tryService.update("TryCompoundRecovery.hx", tryValid);
		tryService.compile("TryCompoundRecovery");
		var tryRepairedState = tryService.compiler.modules.get("TryCompoundRecovery"),
			tryRepairedBindingId = tryRepairedState.semanticModel.index.symbolIdAt(tryBindingPosition);
		if (tryRepairedBindingId == null || Std.string(tryRepairedBindingId) != Std.string(tryValidBindingId)
			|| tryService.completeResult("TryCompoundRecovery.hx", tryValid.length).isIncomplete)
			throw "repair did not restore the exact catch binding identity";
	}

	static function assertRecoveryEquivalence():Void {
		var service = new LanguageService(),
			targetSource = "package matrix; class Box { public var member:Int; } function main():Void return;";
		service.update("matrix/Box.hx", targetSource);
		service.compile("matrix.Box");
		var validSource = "package app; import matrix.Box; function helper(value:Box):Box return value; function main():Void { var box:Box = new Box(); box.member; var tail:Box = box; return; }";
		service.update("app/Main.hx", validSource);
		service.compile("app.Main");
		var validState = service.compiler.modules.get("app.Main"),
			validModel = validState.semanticModel,
			validBoxDeclaration = validSource.indexOf("box:Box"),
			validBoxUse = validSource.lastIndexOf("box;"),
			validTailType = validSource.indexOf("tail:Box") + "tail:".length,
			validBoxId = validModel.index.symbolIdAt(validBoxDeclaration),
			validBoxUseId = validModel.index.symbolIdAt(validBoxUse),
			validTypeId = validModel.index.symbolIdAt(validTailType);
		if (validBoxId == null || validBoxUseId == null || validTypeId == null || Std.string(validBoxId) != Std.string(validBoxUseId))
			throw "equivalence fixture did not establish valid local and type identities";

		var malformedSource = "package app; import matrix.Box; function helper(value:Box):Box return value; function main():Void { var box:Box = new Box(); box.member; broken.unresolved().thing; another.unresolved().thing; var tail:Box = box; return; }";
		service.update("app/Main.hx", malformedSource);
		var malformedState = service.compiler.modules.get("app.Main"),
			recoveredModel = malformedState.recoveredSemanticModel,
			malformedBoxDeclaration = malformedSource.indexOf("box:Box"),
			malformedBoxUse = malformedSource.lastIndexOf("box;"),
			malformedTailType = malformedSource.indexOf("tail:Box") + "tail:".length,
			recoveredBoxId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedBoxDeclaration),
			recoveredBoxUseId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedBoxUse),
			recoveredTypeId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedTailType),
			completion = service.completeResult("app/Main.hx", malformedSource.indexOf("box.member") + "box.".length),
			symbols = service.documentSymbols("app/Main.hx"),
			hasMember = false;
		for (item in completion.items)
			if (item.label == "member")
				hasMember = true;
		if (recoveredModel == null
			|| recoveredBoxId == null
			|| recoveredBoxUseId == null
			|| recoveredTypeId == null
			|| Std.string(recoveredBoxId) != Std.string(validBoxId)
			|| Std.string(recoveredBoxUseId) != Std.string(validBoxUseId)
			|| Std.string(recoveredTypeId) != Std.string(validTypeId)
			|| symbols.length < 2
			|| !hasMember
			|| !completion.isIncomplete)
			throw "recovered snapshot did not preserve unaffected local/type identities and current completion";

		var definition = service.definition("app/Main.hx", malformedBoxUse + 1),
			typeDefinition = service.typeDefinition("app/Main.hx", malformedTailType),
			references = service.references("app/Main.hx", malformedBoxUse + 1),
			currentReference = false;
		for (reference in references)
			if (reference.path == "app/Main.hx" && !reference.stale)
				currentReference = true;
		if (definition == null
			|| definition.stale
			|| definition.span.start != malformedBoxDeclaration
			|| typeDefinition == null
			|| typeDefinition.path != "matrix/Box.hx"
			|| !currentReference)
			throw "recovered navigation did not remain equivalent around an unrelated malformed statement";

		service.update("app/Main.hx", validSource);
		service.compile("app.Main");
		var repairedState = service.compiler.modules.get("app.Main"),
			repairedModel = repairedState.semanticModel,
			repairedBoxId = repairedModel.index.symbolIdAt(validBoxDeclaration),
			repairedBoxUseId = repairedModel.index.symbolIdAt(validBoxUse),
			repairedCompletion = service.completeResult("app/Main.hx", validSource.length);
		if (repairedBoxId == null
			|| repairedBoxUseId == null
			|| Std.string(repairedBoxId) != Std.string(validBoxId)
			|| Std.string(repairedBoxUseId) != Std.string(validBoxUseId)
			|| repairedCompletion.isIncomplete)
			throw "repair did not restore the exact snapshot and stable local identity";
	}

	static function assertHealthySnapshot(service:LanguageService, source:String, tail:String):Void {
		var symbols = service.documentSymbols("Interactive.hx");
		if (symbols.length < 2)
			throw 'interactive edit "$tail" lost structural symbols';
		for (symbol in symbols)
			assertSpan(symbol.span, source.length, "symbol", tail);
		for (diagnostic in service.diagnostics("Interactive.hx"))
			assertSpan(diagnostic.span, source.length, "diagnostic", tail);
		for (token in service.semanticTokens("Interactive.hx"))
			assertSpan(token.span, source.length, "semantic token", tail);
	}

	static function assertContains(items:Array<compiler.service.LanguageService.CompletionItem>, name:String, tail:String):Void {
		for (item in items)
			if (item.label == name)
				return;
		throw 'completion for "$tail" did not contain "$name"';
	}

	static function assertSymbol(symbols:Array<compiler.service.LanguageService.DocumentSymbol>, name:String, tail:String):Void {
		for (symbol in symbols)
			if (symbol.name == name)
				return;
		throw 'edit "$tail" did not retain symbol "$name"';
	}

	static function assertSpan(span:SourceSpan, length:Int, kind:String, tail:String):Void {
		if (span.start < 0 || span.end < span.start || span.end > length)
			throw '$kind span ${span.start}-${span.end} escaped "$tail" source length $length';
	}
}
