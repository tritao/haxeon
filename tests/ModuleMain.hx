import compiler.hl.HlWriter;
import compiler.hl.HlPatchReader;
import compiler.ir.HlLower;
import compiler.modules.Compiler;
import compiler.Diagnostic.CompileError;
import sys.io.File;
import compiler.types.Type.CompilerType;
import compiler.modules.CompilerPublication.ReconnectDecision;
import compiler.modules.ModuleState.SemanticDependencyKind;

class ModuleMain {
	static function main():Void {
		var output = Sys.args()[0], compiler = new Compiler();
		compiler.registerNative("print", "std", "sys_print", [TString], TVoid);
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		compiler.update("Main.hx", "function main():Int { print(\"native registration works\\n\"); return Math.add(20, 22); }");
		compiler.update("Unused.hx", "function identity(x:Int):Int { return x; }");
		var first = compiler.compile("Main");
		var mainDependencies = compiler.modules.get("Main").semanticDependencies.get("main"),
			hasBodyDependency = false;
		for (dependency in mainDependencies)
			if (dependency.kind == Body && dependency.target == "Math.add")
				hasBodyDependency = true;
		if (!hasBodyDependency)
			throw "Semantic dependency graph did not record the imported body call";
		if (first.metrics.modules != 3 || first.metrics.retypedFunctions == 0 || first.metrics.moduleNatives <= 1 || first.metrics.elapsedMs < 0.0)
			throw "Compile metrics did not describe the initial module build";
		try {
			compiler.registerNative("late", "std", "sys_time", [], TFloat);
			throw "late native registration was accepted";
		} catch (error:String) {
			if (error != "Native registrations are frozen after the first compilation")
				throw error;
		}
		var mathIndex = first.functionIndices.get("Math.add"),
			mathId = first.functionIds.get("Math.add");
		var twentyIndex = first.module.ints.indexOf(20);
		compiler.update("Aardvark.hx", "function helper(x:Int):Int { return x + 7; }");
		var added = compiler.compile("Main");
		if (added.functionIndices.get("Math.add") != mathIndex)
			throw "Adding an earlier module renumbered Math.add";
		if (added.functionIds.get("Math.add") != mathId)
			throw "Adding a function changed the stable Math.add identity";
		if (added.module.ints.indexOf(20) != twentyIndex)
			throw "Adding a constant renumbered an existing constant";
		var firstBytes = HlWriter.encode(added.module);
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { var sum = a + b; return sum; }");
		var result = compiler.compile("Main");
		if (result.retyped.join(",") != "Math.add")
			throw 'Body edit invalidated callers: ${result.retyped}';
		if (compiler.modules.get("Main").parseVersion != 1)
			throw "Dependent module was reparsed";
		if (compiler.modules.get("Main").typeVersion != 1)
			throw "Body edit retyped dependent module";
		if (compiler.modules.get("Main").irSourceRevisions.get("main") != 1
			|| compiler.modules.get("Math").irSourceRevisions.get("Math.add") != 2)
			throw "Cached IR was not tied to its source revision";
		if (compiler.modules.get("Math").irVersions.get("Math.add") != 2)
			throw "Edited function IR was not regenerated";
		if (result.changedFunctions.length != 1 || result.changedFunctions[0] != result.functionIds.get("Math.add"))
			throw 'Wrong changed stable functions: ${result.changedFunctions}';
		if (result.patchBytes == null)
			throw "Compatible body edit did not emit HLP bytes";
		if (result.metrics.changedFunctions != 1 || result.metrics.patchBytes != result.patchBytes.length)
			throw "Compile metrics did not describe the compatible patch";
		var decodedPatch = HlPatchReader.decode(result.patchBytes);
		if (decodedPatch.functions.length != 1 || decodedPatch.functions[0].functionIndex != mathId)
			throw "Compiler HLP did not contain exactly the changed function";
		if (result.requiresReload)
			throw "Body edit unexpectedly requires reload";
		if (compiler.modules.get("Unused").parseVersion != 1 || compiler.modules.get("Unused").typeVersion != 1)
			throw "Unrelated module was not reused";
		var secondBytes = HlWriter.encode(result.module);
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
		if (unrelated.regenerated.join(",") != "Unused.identity")
			throw 'Unrelated edit regenerated ${unrelated.regenerated}';
		if (compiler.modules.get("Main").irFunctions.get("main") != mainIr
			|| compiler.modules.get("Math").irFunctions.get("Math.add") != mathIr)
			throw "Unrelated edit replaced cached IR objects";
		compiler.update("Temp.hx", "function oldValue():Int { return 3; }");
		var withOld = compiler.compile("Main"),
			oldIndex = withOld.functionIndices.get("Temp.oldValue"),
			oldId = withOld.functionIds.get("Temp.oldValue");
		compiler.update("Temp.hx", "function freshValue():Int { return 4; }");
		var removed = compiler.compile("Main");
		if (removed.functionIndices.get("Temp.oldValue") != oldIndex || removed.functionIndices.get("Temp.freshValue") <= oldIndex)
			throw "Removed function slot was not retained as a tombstone";
		if (removed.functionIds.get("Temp.oldValue") != oldId || removed.functionIds.get("Temp.freshValue") == oldId)
			throw "Function removal reused or changed a stable identity";
		if (!removed.requiresReload)
			throw "Removing a function did not require reload";
		var unchanged = compiler.compile("Main");
		if (unchanged.changedFunctions.length != 0 || unchanged.requiresReload)
			throw "Unchanged build reported changes";
		var compacted = compiler.compact("Main");
		if (compacted.functionIndices.exists("Temp.oldValue"))
			throw "Compact build retained tombstone";
		if (compacted.functionIds.get("Math.add") != mathId)
			throw "Compaction changed a live function identity";
		var resumed = new Compiler(compiler.exportIdentityState());
		resumed.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		resumed.update("Main.hx", "function main():Int { return Math.add(20, 22); }");
		var resumedBuild = resumed.compile("Main");
		if (resumedBuild.functionIds.get("Math.add") != mathId
			|| resumedBuild.runtimeIdentity.sub(4, 16).compare(compacted.runtimeIdentity.sub(4, 16)) != 0)
			throw "Serialized compiler identity did not survive restart";
		var layoutA = new Compiler(), layoutB = new Compiler();
		layoutA.registerNative("clock", "std", "sys_time", [], TFloat);
		layoutB.registerNative("clock", "std", "sys_time", [], TFloat);
		layoutB.registerNative("print", "std", "sys_print", [TString], TVoid);
		layoutA.update("Main.hx", "function main():Int { return 1; }");
		layoutB.update("Main.hx", "function main():Int { return 1; }");
		var buildA = layoutA.compile("Main"), buildB = layoutB.compile("Main");
		if (buildA.functionIds.get("main") != buildB.functionIds.get("main"))
			throw "Native layout changed persistent user-function identity";
		if (buildA.functionIndices.get("main") == buildB.functionIndices.get("main"))
			throw "Test did not exercise distinct backend native layouts";
		File.saveBytes(output, HlWriter.encode(compacted.module));

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
		functionValueCompiler.update("Main.hx", "function twice(value:Int):Int { return value * 2; } function main():Int { var f = twice; return f(21); }");
		var functionValueFirst = functionValueCompiler.compile("Main"),
			functionValueMain = functionValueCompiler.modules.get("Main").irFunctions.get("main");
		functionValueCompiler.update("Main.hx", "function twice(value:Int):Int { return value + value; } function main():Int { var f = twice; return f(21); }");
		var functionValueBody = functionValueCompiler.compile("Main");
		if (functionValueBody.retyped.join(",") != "Main.twice")
			throw 'Function-value body edit invalidated ${functionValueBody.retyped}';
		functionValueCompiler.update("Main.hx", "function twice(value:Float):Int { return 42; } function main():Int { var f = twice; return f(21); }");
		try {
			functionValueCompiler.compile("Main");
			throw "Function-value signature edit was accepted";
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1009")
				throw error;
		}
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
		var lambdaFirst = lambdaCompiler.compile("Main"),
			lambdaId = lambdaFirst.functionIds.get("$lambda:main:30");
		if (lambdaId == null)
			throw "Generated lambda did not receive a stable function identity";
		var lambdaUnchanged = lambdaCompiler.compile("Main");
		if (lambdaUnchanged.changedFunctions.length != 0)
			throw "Unchanged lambda build reported changes";
		lambdaCompiler.update("Main.hx", "function main():Int { var f = () -> { return 41 + 1; }; return f(); }");
		var lambdaBody = lambdaCompiler.compile("Main");
		if (lambdaBody.functionIds.get("$lambda:main:30") != lambdaId || lambdaBody.retyped.length != 2)
			throw "Lambda body edit did not preserve or regenerate its generated function";
		var capturedCompiler = new Compiler();
		capturedCompiler.update("Main.hx", "function main():Int { var offset = 21; var f = (value:Int) -> { return value + offset; }; return f(21); }");
		var capturedFirst = capturedCompiler.compile("Main"),
			capturedLambdaId:Null<Int> = null;
		for (name => id in capturedFirst.functionIds)
			if (StringTools.startsWith(name, "$lambda:"))
				capturedLambdaId = id;
		if (capturedLambdaId == null || capturedFirst.ir.objects.length == 0)
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
		if (methodBuild.patchBytes == null)
			throw "Dynamic method body edit did not emit HLP bytes";
		if (HlPatchReader.decode(methodBuild.patchBytes).functions.length == 0)
			throw "Dynamic method HLP patch was empty";
		var callManyCompiler = new Compiler();
		callManyCompiler.update("Main.hx", "function sum(a:Int, b:Int, c:Int):Int { return a + b + c; } function main():Int { return sum(10, 20, 12); }");
		callManyCompiler.compile("Main");
		callManyCompiler.update("Main.hx", "function sum(a:Int, b:Int, c:Int):Int { return a + b + c; } function main():Int { return sum(11, 20, 12); }");
		var callManyBuild = callManyCompiler.compile("Main"),
			callManyPatch = HlPatchReader.decode(callManyBuild.patchBytes);
		if (callManyPatch.functions.length != 1 || callManyPatch.functions[0].relocations.length != 1)
			throw "OCallN stable relocation was not emitted";
		var validationCompiler = new Compiler();
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
		var publicationCompiler = new Compiler();
		publicationCompiler.enablePublicationTracking();
		publicationCompiler.update("Main.hx", "function main():Int { return 40; }");
		var publicationInitial = publicationCompiler.compile("Main");
		if (publicationCompiler.publicationStatus().acknowledgedRevision != 0
			|| publicationCompiler.publicationStatus().pendingRevision != publicationInitial.revision)
			throw "Emitted initial build advanced the acknowledged runtime baseline";
		try {
			publicationCompiler.compile("Main");
			throw "Compiler accepted a second build while publication was pending";
		} catch (error:String) {
			if (error.indexOf("is still pending") < 0)
				throw error;
		}
		publicationCompiler.acknowledgePublication(publicationInitial.revision);
		switch publicationCompiler.reconcileRuntime(publicationInitial.runtimeIdentity.sub(4, 16), publicationInitial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Live acknowledged compiler required reload: $reason';
		}
		switch publicationCompiler.reconcileRuntime(publicationInitial.runtimeIdentity.sub(4, 16), publicationInitial.revision + 1) {
			case ContinuePatching:
				throw "Mismatched runtime revision was accepted";
			case ReloadDomain(_):
		}
		var resumedPublicationCompiler = new Compiler(publicationCompiler.exportIdentityState());
		if (!resumedPublicationCompiler.publicationStatus().tracking
			|| resumedPublicationCompiler.publicationStatus().acknowledgedRevision != publicationInitial.revision)
			throw "Compiler restart lost the acknowledged publication baseline";
		switch resumedPublicationCompiler.reconcileRuntime(publicationInitial.runtimeIdentity.sub(4, 16), publicationInitial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Restored backend baseline required reload: $reason';
		}
		publicationCompiler.update("Main.hx", "function main():Int { return 41; }");
		var rejectedPublication = publicationCompiler.compile("Main");
		try {
			publicationCompiler.exportIdentityState();
			throw "Compiler persisted an unacknowledged candidate";
		} catch (error:String) {
			if (error.indexOf("Cannot persist pending publication") < 0)
				throw error;
		}
		publicationCompiler.rejectPublication(rejectedPublication.revision);
		if (publicationCompiler.publicationStatus().acknowledgedRevision != publicationInitial.revision
			|| publicationCompiler.publicationStatus().pendingRevision != null)
			throw "Rejected build advanced or left the runtime publication baseline pending";
		var retriedPublication = publicationCompiler.compile("Main");
		if (retriedPublication.revision != rejectedPublication.revision
			|| retriedPublication.patchBytes.compare(rejectedPublication.patchBytes) != 0)
			throw "Retry after runtime rejection disagreed with the rejected candidate";
		publicationCompiler.acknowledgePublication(retriedPublication.revision);
		var structuralCompiler = new Compiler();
		structuralCompiler.update("Main.hx",
			"class Editor { public var value:Int; public function new():Void { this.value = 42; } } function main():Int { var editor = new Editor(); return editor.value; }");
		structuralCompiler.compile("Main");
		structuralCompiler.update("Main.hx",
			"class Editor { public var value:Int; public var generation:Int; public function new():Void { this.value = 42; this.generation = 1; } } function main():Int { var editor = new Editor(); return editor.value; }");
		var structuralBuild = structuralCompiler.compile("Main");
		if (!structuralBuild.requiresReload
			|| structuralBuild.patchBytes != null
			|| [for (reason in structuralBuild.reloadReasons) Std.string(reason)].indexOf("ObjectLayoutChanged(Editor)") < 0)
			throw "Class layout edit did not require a full reload";
		Sys.println("PASS: function fingerprints selectively retyped and regenerated cached artifacts");
	}
}
