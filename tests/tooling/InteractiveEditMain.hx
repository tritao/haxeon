import compiler.Source.SourceSpan;
import compiler.service.LanguageService;

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

		Sys.println('PASS: ${tails.length + 13} interactive edits retained recovery queries');
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
