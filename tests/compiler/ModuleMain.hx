using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.hl.HlWriter;
import compiler.hl.lower.HlLower;
import compiler.hl.patch.HlSectionPatch;
import compiler.ir.passes.inlining.IrInliner;
import compiler.semantic.DeclarationFacts.FactAspect;
import compiler.types.Type.CompilerType;
import sys.io.File;

class ModuleMain {
	static function main():Void {
		var output = Sys.args()[0], compiler = new Compiler();
		compiler.registerNative("print", "haxeon_runtime", "__sys_print", [TString], TVoid);
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		compiler.update("Main.hx",
			"function main():Int { print(\"native registration works\\n\"); return Math.add(20, 22); }");
		compiler.update("Unused.hx", "function identity(x:Int):Int { return x; }");
		compiler.update("BrokenUnused.hx", "function broken(:Int { }");
		var first = compiler.compile("Main");
		var noOp = compiler.compile("Main");
		if (noOp.revision != first.revision
			|| noOp.artifact.hashLink().module != first.artifact.hashLink().module
			|| noOp.metrics.retypedFunctions != 0
			|| noOp.metrics.regeneratedFunctions != 0
			|| noOp.changedFunctions.length != 0
			|| noOp.artifact.hashLink().patchBytes != null)
			throw "Unchanged compilation did not reuse the last successful build";
		var facts = compiler.state.declarationFacts,
			mainReads = facts.unitRecord(facts.existing(FactAspect.Unit, "main"));
		if (mainReads == null || mainReads.reads.indexOf(facts.existing(FactAspect.Signature, "Math.add")) < 0)
			throw "Typing did not record that main read the signature of the function it calls";
		if (first.metrics.modules != 2 || first.metrics.retypedFunctions == 0 || first.metrics.moduleNatives <= 1
			|| first.metrics.elapsedMs < 0.0)
			throw 'Compile metrics did not describe the initial module build: modules=${first.metrics.modules}, retyped=${first.metrics.retypedFunctions}, natives=${first.metrics.moduleNatives}, elapsed=${first.metrics.elapsedMs}';
		if (first.metrics.declarationMs < 0.0
			|| first.metrics.shapeConnectionMs < 0.0
			|| first.metrics.signatureTypingMs < 0.0
			|| first.metrics.bodyTransitionMs < 0.0
			|| first.metrics.finalizationTransitionMs < 0.0)
			throw "Compile metrics did not describe declaration lifecycle transitions";
		try {
			compiler.registerNative("late", "std", "sys_time", [], TFloat);
			throw "late native registration was accepted";
		} catch (error:InternalError) {
			if (error.message != "Native registrations are frozen after the first compilation")
				throw error;
		}
		var twentyIndex = first.artifact.hashLink().module.ints.indexOf(20);
		compiler.update("Aardvark.hx", "function helper(x:Int):Int { return x + 7; }");
		var added = compiler.compile("Main");
		if (added.artifact.hashLink().module.ints.indexOf(20) != twentyIndex)
			throw "Adding a constant renumbered an existing constant";
		var firstBytes = HlWriter.encodeFunction(functionNamed(added.artifact.hashLink().module, "Math.add")),
			unchangedMain = compiler.modules.get("Main"),
			addIr = compiler.modules.get("Math").irFunctions.get("Math.add");
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { var sum = a + b; return sum; }");
		var result = compiler.compile("Main");
		if (compiler.modules.get("Main") != unchangedMain)
			throw "Body edit copied an unchanged dependent module";
		if (result.retyped.join(",") != "Math.add")
			throw 'Body edit invalidated callers: ${result.retyped}';
		if (compiler.modules.get("Main").parseVersion != 1)
			throw "Dependent module was reparsed";
		if (compiler.modules.get("Main").typeVersion != 1)
			throw "Body edit retyped dependent module";
		if (compiler.modules.get("Main").irSourceRevisions.get("main") != 1
			|| compiler.modules.get("Math").irSourceRevisions.get("Math.add") != 2)
			throw "Cached IR was not tied to its source revision";
		if (compiler.modules.get("Math").irFunctions.get("Math.add") == addIr)
			throw "Edited function IR was not regenerated";
		// Typing and IR regeneration touch only the edited function, and the caller that inlined it.
		var expectedChanged = 2;
		if (result.changedFunctions.join(",") != "Math.add,main")
			throw 'Wrong changed functions: ${result.changedFunctions}';
		if (result.artifact.hashLink().patchBytes == null)
			throw "Compatible body edit did not emit HLP bytes";
		if (result.metrics.changedFunctions != expectedChanged
			|| result.metrics.patchBytes != result.artifact.hashLink().patchBytes.length)
			throw "Compile metrics did not describe the compatible patch";
		var replaced = [
			for (section in HlSectionPatch.decode(result.artifact.hashLink().patchBytes).content.replaced) section.path
		];
		// `main` is named after no declaration, so it is in the shared section.
		if (replaced.join(",") != "Math,$shared")
			throw 'Compiler HLP did not replace exactly the sections of the changed function and its inlining caller: $replaced';
		if (result.requiresReload)
			throw "Body edit unexpectedly requires reload";
		if (compiler.modules.get("Unused").parseVersion != 0 || compiler.modules.get("Unused").typeVersion != 0)
			throw 'Unreachable module had unexpected work: parse=${compiler.modules.get("Unused").parseVersion}, type=${compiler.modules.get("Unused").typeVersion}';
		var secondBytes = HlWriter.encodeFunction(functionNamed(result.artifact.hashLink().module, "Math.add"));
		if (firstBytes.compare(secondBytes) != 0)
			throw "Equivalent incremental builds were not deterministic";
		var committedIdentity = compiler.exportIdentityState(),
			committedMathIr = compiler.modules.get("Math").irFunctions.get("Math.add"),
			committedMathTypeVersion = compiler.modules.get("Math").typeVersion;
		compiler.update("Math.hx", "function add(a:Int, b:Int):Bool { return a < b; }");
		try {
			compiler.compile("Main");
			throw "incompatible signature edit was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1003")
				throw error;
		}
		if (compiler.exportIdentityState().compare(committedIdentity) != 0
			|| compiler.modules.get("Math").irFunctions.get("Math.add") != committedMathIr
			|| compiler.modules.get("Math").typeVersion != committedMathTypeVersion)
			throw "Failed compilation changed committed compiler state";
		var failedDiagnosticCount = 0;
		for (state in compiler.modules)
			failedDiagnosticCount += state.diagnostics.length;
		if (compiler.modules.get("Math").source.text.indexOf(":Bool") < 0 || failedDiagnosticCount == 0)
			throw "Failed compilation did not retain the current document and diagnostic";
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		var restored = compiler.compile("Main");
		if (restored.requiresReload || restored.revision != result.revision + 1)
			throw "Restoring an unpublished invalid signature required reload";
		var mainIr = compiler.modules.get("Main").irFunctions.get("main");
		var mathIr = compiler.modules.get("Math").irFunctions.get("Math.add");
		compiler.update("Unused.hx", "function identity(x:Int):Int { var copy = x; return copy; }");
		var unrelated = compiler.compile("Main");
		if (unrelated.regenerated.length != 0)
			throw 'Unrelated edit regenerated ${unrelated.regenerated}';
		if (compiler.modules.get("Main").irFunctions.get("main") != mainIr
			|| compiler.modules.get("Math").irFunctions.get("Math.add") != mathIr)
			throw "Unrelated edit replaced cached IR objects";
		compiler.update("Temp.hx", "function oldValue():Int { return 3; }");
		compiler.update("Main.hx",
			"import Temp; function main():Int { print(\"native registration works\\n\"); return Math.add(20, 22); }");
		var withOld = compiler.compile("Main"),
			oldIndex = withOld.artifact.hashLink().functionIndices.get("Temp.oldValue");
		compiler.update("Temp.hx", "function freshValue():Int { return 4; }");
		var removed = compiler.compile("Main");
		if (removed.artifact.hashLink().functionIndices.get("Temp.oldValue") != oldIndex
			|| removed.artifact.hashLink().functionIndices.get("Temp.freshValue") <= oldIndex)
			throw "Removed function slot was not retained as a tombstone";
		// A removed function keeps its slot and last body, which the new code no longer calls, so the removal patches.
		if (removed.requiresReload)
			throw "Removing a function required reload";
		var unchanged = compiler.compile("Main");
		if (unchanged.changedFunctions.length != 0 || unchanged.requiresReload)
			throw "Unchanged build reported changes";
		var compacted = compiler.compact("Main");
		if (compacted.artifact.hashLink().functionIndices.exists("Temp.oldValue"))
			throw "Compact build retained tombstone";
		var resumed = new Compiler(compiler.exportIdentityState());
		resumed.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		resumed.update("Main.hx", "function main():Int { return Math.add(20, 22); }");
		var resumedBuild = resumed.compile("Main");
		if (!resumedBuild.artifact.hashLink().functionIndices.exists("Math.add")
			|| resumedBuild.artifact.hashLink().runtimeIdentity.sub(4,
			16).compare(compacted.artifact.hashLink().runtimeIdentity.sub(4, 16)) != 0)
			throw "Serialized compiler identity did not survive restart";
		File.saveBytes(output, compacted.artifact.hashLink().hashLinkBytes().flatten());

		var missing = new Compiler();
		missing.update("Main.hx", "function main():Int { return Missing.value(); }");
		try {
			missing.compile("Main");
			throw "missing module was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E2001")
				throw error;
			if (missing.modules.get("Main").diagnostics.length != 1)
				throw "module did not retain its diagnostic";
		}
		var functionValueCompiler = new Compiler();
		functionValueCompiler.update("Main.hx",
			"function twice(value:Int):Int { return value * 2; } function main():Int { var f = twice; return f(21); }");
		var functionValueFirst = functionValueCompiler.compile("Main"),
			functionValueMain = functionValueCompiler.modules.get("Main").irFunctions.get("main");
		functionValueCompiler.update("Main.hx",
			"function twice(value:Int):Int { return value + value; } function main():Int { var f = twice; return f(21); }");
		var functionValueBody = functionValueCompiler.compile("Main");
		if (functionValueBody.retyped.join(",") != "Main.twice")
			throw 'Function-value body edit invalidated ${functionValueBody.retyped}';
		functionValueCompiler.update("Main.hx",
			"function twice(value:Float):Int { return 42; } function main():Int { var f = twice; return f(21); }");
		var functionValueSignature = functionValueCompiler.compile("Main");
		if (functionValueSignature.retyped.indexOf("Main.twice") < 0
			|| functionValueSignature.retyped.indexOf("main") < 0)
			throw 'Function-value signature edit did not retype callee and caller: ${functionValueSignature.retyped}';
		if (functionValueFirst.ir.functions.length == 0 || functionValueMain == null)
			throw "Function-value incremental setup did not compile";
		var semanticInvalidation = new Compiler();
		semanticInvalidation.update("Main.hx",
			"typedef Value = Int; function use(value:Value):Value { return value; } function idle():Int { return 1; } function main():Int { return use(42); }");
		semanticInvalidation.compile("Main");
		semanticInvalidation.update("Main.hx",
			"typedef Value = Bool; function use(value:Value):Value { return value; } function idle():Int { return 1; } function main():Int { use(true); return 42; }");
		var semanticEdit = semanticInvalidation.compile("Main");
		if (semanticEdit.retyped.indexOf("Main.idle") >= 0
			|| semanticEdit.retyped.indexOf("Main.use") < 0
			|| semanticEdit.retyped.indexOf("main") < 0)
			throw 'Semantic alias edit invalidated ${semanticEdit.retyped}';
		var lambdaCompiler = new Compiler();
		lambdaCompiler.update("Main.hx", "function main():Int { var f = () -> { return 42; }; return f(); }");
		// A lambda is named by where it is written (LambdaName); the test only needs the one lambda in main.
		function lambdaIn(indices:Map<String, Int>):Null<String> {
			for (name in indices.keys())
				if (StringTools.startsWith(name, "$lambda:main:main#"))
					return name;
			return null;
		}
		var lambdaFirst = lambdaCompiler.compile("Main"),
			lambdaName = lambdaIn(lambdaFirst.artifact.hashLink().functionIndices);
		if (lambdaName == null)
			throw "The lambda did not become a function of the module";
		var lambdaUnchanged = lambdaCompiler.compile("Main");
		if (lambdaUnchanged.changedFunctions.length != 0)
			throw "Unchanged lambda build reported changes";
		lambdaCompiler.update("Main.hx", "function main():Int { var f = () -> { return 41 + 1; }; return f(); }");
		var lambdaBody = lambdaCompiler.compile("Main");
		if (lambdaIn(lambdaBody.artifact.hashLink().functionIndices) != lambdaName || lambdaBody.retyped.length != 2)
			throw "Lambda body edit did not preserve or regenerate its generated function";
		var capturedCompiler = new Compiler();
		capturedCompiler.update("Main.hx",
			"function main():Int { var offset = 21; var f = (value:Int) -> { return value + offset; }; return f(21); }");
		var capturedFirst = capturedCompiler.compile("Main"),
			capturedLambda:Null<String> = null;
		for (name in capturedFirst.artifact.hashLink().functionIndices.keys())
			if (StringTools.startsWith(name, "$lambda:"))
				capturedLambda = name;
		if (capturedLambda == null || capturedFirst.ir.objects.length == 0)
			throw "Captured lambda did not retain its generated environment type";
		var capturedUnchanged = capturedCompiler.compile("Main");
		if (capturedUnchanged.changedFunctions.length != 0)
			throw "Unchanged captured lambda build reported changes";
		var methodCompiler = new Compiler();
		methodCompiler.update("Main.hx",
			"class Editor { public function get():Int { return 20; } } function main():Int { var editor = new Editor(); return editor.get() + 22; }");
		methodCompiler.compile("Main");
		methodCompiler.update("Main.hx",
			"class Editor { public function get():Int { return 21; } } function main():Int { var editor = new Editor(); return editor.get() + 21; }");
		var methodBuild = methodCompiler.compile("Main");
		if (methodBuild.artifact.hashLink().patchBytes == null)
			throw "Dynamic method body edit did not emit HLP bytes";
		if (HlSectionPatch.decode(methodBuild.artifact.hashLink().patchBytes).content.replaced.length == 0)
			throw "Dynamic method HLP patch was empty";
		// A section names the functions it calls by key; keep the inliner out of this check, so the call stays.
		var callManyCompiler = new Compiler();
		callManyCompiler.options = new CompileOptions({inlining: false});
		callManyCompiler.update("Main.hx",
			"function sum(a:Int, b:Int, c:Int):Int { return a + b + c; } function main():Int { return sum(10, 20, 12); }");
		callManyCompiler.compile("Main");
		callManyCompiler.update("Main.hx",
			"function sum(a:Int, b:Int, c:Int):Int { return a + b + c; } function main():Int { return sum(11, 20, 12); }");
		var callManyBuild = callManyCompiler.compile("Main"),
			callManyPatch = HlSectionPatch.decode(callManyBuild.artifact.hashLink().patchBytes).content;
		// `main` is in the shared section; Main's carries the edited file's source snapshot and the spans that hash it.
		if ([for (section in callManyPatch.replaced) section.path].join(",") != "Main,$shared"
			|| callManyPatch.renames.length != 0)
			throw 'A body edit of an OCallN caller replaced other sections than its own and its file\'s: ${[for (section in callManyPatch.replaced) section.path]}';
		var validationCompiler = new Compiler();
		validationCompiler.registerNative("clock", "std", "sys_time", [], TFloat);
		validationCompiler.update("Main.hx", "function main():Int { return 42; }");
		validationCompiler.compile("Main");
		var previousSource = validationCompiler.modules.get("Main").source.text,
			invalidEdit = validationCompiler.validate("Main.hx", "function main():Int { return \"bad\"; }", "Main");
		if (invalidEdit.valid || invalidEdit.diagnostic == null || invalidEdit.diagnostic.code != "E1003")
			throw "Invalid transactional edit was accepted";
		if (validationCompiler.modules.get("Main").source.text != previousSource)
			throw "Transactional validation mutated the live source snapshot";
		if (!validationCompiler.validate("Main.hx", previousSource, "Main").valid)
			throw "Valid transactional edit was rejected";
		validationCompiler.enablePublicationTracking();
		var trackedValidation = validationCompiler.compile("Main");
		validationCompiler.acknowledgePublication(trackedValidation.revision);
		if (!validationCompiler.validate("Main.hx", previousSource, "Main").valid)
			throw "Validation lost native configuration after publication";
		// A file loaded under an explicit module name is validated under that name, not the one its path gives.
		var namedValidation = new Compiler();
		namedValidation.update("tools/Run.hx", "function main():Int { return 1; }", "Run");
		namedValidation.compile("Run");
		if (!namedValidation.validate("tools/Run.hx", "function main():Int { return 2; }", "Run").valid
			|| namedValidation.validate("tools/Run.hx", "function main():Int { return \"bad\"; }", "Run").valid
			|| namedValidation.modules.get("Run").source.text != "function main():Int { return 1; }")
			throw "Validation lost the explicit module name of the edited file, or changed its live source";
		var failedCompact = new Compiler();
		failedCompact.update("Main.hx", "function main():Int { return 40; }");
		var beforeCompactFailure = failedCompact.compile("Main");
		failedCompact.update("Main.hx", "function main():Int { return \"bad\"; }");
		try
			failedCompact.compact("Main")
		catch (_:CompileError) {}
		failedCompact.update("Main.hx", "function main():Int { return 41; }");
		var afterCompactFailure = failedCompact.compile("Main");
		if (afterCompactFailure.revision != beforeCompactFailure.revision + 1
			|| afterCompactFailure.artifact.hashLink().patchBytes == null)
			throw "Failed compaction discarded the published backend baseline";
		var publicationCompiler = new Compiler();
		publicationCompiler.enablePublicationTracking();
		publicationCompiler.update("Main.hx", "function main():Int { return 40; }");
		var publicationInitial = publicationCompiler.compile("Main");
		if (publicationCompiler.publicationStatus().acknowledgedRevision != 0
			|| !publicationCompiler.publicationStatus().hasPendingRevision
			|| publicationCompiler.publicationStatus().pendingRevision != publicationInitial.revision)
			throw "Emitted initial build advanced the acknowledged runtime baseline";
		try {
			publicationCompiler.compile("Main");
			throw "Compiler accepted a second build while publication was pending";
		} catch (error:InternalError) {
			if (error.message.indexOf("is still pending") < 0)
				throw error;
		}
		publicationCompiler.acknowledgePublication(publicationInitial.revision);
		for (_ in 0...2) {
			var unchangedPublication = publicationCompiler.compile("Main");
			if (!unchangedPublication.unchanged
				|| unchangedPublication.revision != publicationInitial.revision
				|| unchangedPublication.baseRevision != publicationInitial.revision
				|| unchangedPublication.artifact.hashLink().patchBytes != null
				|| publicationCompiler.publicationStatus().hasPendingRevision)
				throw "Unchanged build advanced the runtime revision or left publication pending";
			try {
				publicationCompiler.acknowledgePublication(unchangedPublication.revision);
				throw "Unchanged build incorrectly accepted an acknowledgement";
			} catch (error:InternalError) {
				if (error.message != "No publication is pending")
					throw error;
			}
		}

		switch publicationCompiler.reconcileRuntime(publicationInitial.artifact.hashLink().runtimeIdentity.sub(4, 16),
			publicationInitial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Live acknowledged compiler required reload: $reason';
		}
		switch publicationCompiler.reconcileRuntime(publicationInitial.artifact.hashLink().runtimeIdentity.sub(4, 16),
			publicationInitial.revision + 1) {
			case ContinuePatching:
				throw "Mismatched runtime revision was accepted";
			case ReloadDomain(_):
		}
		var resumedPublicationCompiler = new Compiler(publicationCompiler.exportIdentityState());
		if (!resumedPublicationCompiler.publicationStatus().tracking
			|| resumedPublicationCompiler.publicationStatus().acknowledgedRevision != publicationInitial.revision)
			throw "Compiler restart lost the acknowledged publication baseline";
		switch resumedPublicationCompiler.reconcileRuntime(publicationInitial.artifact.hashLink().runtimeIdentity.sub(4,
			16),
			publicationInitial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Restored backend baseline required reload: $reason';
		}
		publicationCompiler.update("Main.hx", "function main():Int { return 41; }");
		var rejectedPublication = publicationCompiler.compile("Main");
		if (rejectedPublication.baseRevision != publicationInitial.revision
			|| rejectedPublication.revision != publicationInitial.revision + 1)
			throw "Changed publication did not start at the last runtime revision";
		try {
			publicationCompiler.exportIdentityState();
			throw "Compiler persisted an unacknowledged candidate";
		} catch (error:InternalError) {
			if (error.message.indexOf("Cannot persist pending publication") < 0)
				throw error;
		}
		publicationCompiler.rejectPublication(rejectedPublication.revision);
		if (publicationCompiler.publicationStatus().acknowledgedRevision != publicationInitial.revision
			|| publicationCompiler.publicationStatus().hasPendingRevision)
			throw "Rejected build advanced or left the runtime publication baseline pending";
		var retriedPublication = publicationCompiler.compile("Main");
		if (retriedPublication.revision != rejectedPublication.revision
			|| retriedPublication.artifact.hashLink().patchBytes
			.compare(rejectedPublication.artifact.hashLink().patchBytes) != 0)
			throw "Retry after runtime rejection disagreed with the rejected candidate";
		publicationCompiler.acknowledgePublication(retriedPublication.revision);
		// A rejected build leaves nothing of its own behind: not its types, nor the generic specializations it named.
		var specializationCompiler = new Compiler();
		specializationCompiler.enablePublicationTracking();
		specializationCompiler.update("Main.hx",
			"function first<T>(values:Array<T>):T { return values[0]; } function main():Int { return first([40]); }");
		specializationCompiler.acknowledgePublication(specializationCompiler.compile("Main").revision);
		var acknowledgedIdentity = specializationCompiler.exportIdentityState(),
			acknowledgedSpecializations =
				@:privateAccess specializationCompiler.state.genericSpecializations.exportState();
		specializationCompiler.update("Main.hx",
			"function first<T>(values:Array<T>):T { return values[0]; } function main():Int { return first([1.5]) > 1.0 ? first([40]) : 0; }");
		var specializationFacts = specializationCompiler.state.declarationFacts,
			mainUnit = specializationFacts.existing(FactAspect.Unit, "main"),
			acknowledgedMain = specializationFacts.unitRecord(mainUnit);
		var specializedBuild = specializationCompiler.compile("Main");
		if (acknowledgedMain == null || specializationFacts.unitRecord(mainUnit) == acknowledgedMain)
			throw "The edited main was not recorded again";
		if (@:privateAccess specializationCompiler.state.genericSpecializations.exportState()
			.compare(acknowledgedSpecializations) == 0)
			throw "The edit that calls a generic function with another type named no new specialization";
		specializationCompiler.rejectPublication(specializedBuild.revision);
		if (specializationCompiler.exportIdentityState().compare(acknowledgedIdentity) != 0)
			throw "Rejecting a build kept its types or generic specializations";
		if (specializationFacts.unitRecord(mainUnit) != acknowledgedMain)
			throw "Rejecting a build kept what its units read";
		var structuralCompiler = new Compiler();
		structuralCompiler.update("Main.hx",
			"class Editor { public var value:Int; public function new():Void { this.value = 42; } } function main():Int { var editor = new Editor(); return editor.value; }");
		structuralCompiler.compile("Main");
		structuralCompiler.update("Main.hx",
			"class Editor { public var value:Int; public var generation:Int; public function new():Void { this.value = 42; this.generation = 1; } } function main():Int { var editor = new Editor(); return editor.value; }");
		var structuralBuild = structuralCompiler.compile("Main");
		// An added field patches the running class: its objects grow the field, initialized by the patch.
		if (structuralBuild.requiresReload || structuralBuild.artifact.hashLink().patchBytes == null)
			throw 'Adding a field did not patch: '
				+ [for (reason in structuralBuild.reloadReasons) Std.string(reason)].join(", ");
		Sys.println("PASS: function fingerprints selectively retyped and regenerated cached artifacts");
	}

	static function functionNamed(module:compiler.hl.HlCode, name:String):compiler.hl.HlFunction {
		var position = module.functionNames.indexOf(name);
		if (position < 0)
			throw 'Missing function $name';
		return module.functions[position];
	}
}
