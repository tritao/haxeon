package compiler.compilation;

import compiler.Diagnostic;
import compiler.Compiler;
import compiler.Compiler.AnalysisResult;
import compiler.modules.ModuleState;
import compiler.service.CancellationError;
import compiler.service.CancellationToken;

/** Runs compiler analysis transactionally without assembling or publishing a runtime artifact. */
class AnalysisTransaction {
	final compiler:Compiler;
	final entryModule:String;
	final token:Null<CancellationToken>;

	public function new(compiler:Compiler, entryModule:String, token:Null<CancellationToken>) {
		this.compiler = compiler;
		this.entryModule = entryModule;
		this.token = token;
	}

	public function run():AnalysisResult {
		var generation = compiler.currentSourceGeneration(),
			snapshot = compiler.snapshot(),
			candidate = compiler.createCandidate(snapshot, null),
			context = new CompilationContext(candidate),
			startedAt = Sys.time() * 1000.0;
		if (!compiler.isSourceGenerationCurrent(generation))
			throw new CancellationError();
		var diagnosticWork = [entryModule],
			diagnosticSeen:Map<String, Bool> = [],
			diagnosticCursor = 0;
		while (diagnosticCursor < diagnosticWork.length) {
			var name = diagnosticWork[diagnosticCursor++];
			if (diagnosticSeen.exists(name) || !candidate.modules.exists(name))
				continue;
			diagnosticSeen.set(name, true);
			var state = context.writableState(name, snapshot.modules);
			state.diagnostics = [];
			for (dependency in state.dependencies)
				diagnosticWork.push(dependency);
		}
		try {
			var frontend = FrontendCompilation.run(context, entryModule, token, snapshot.modules, startedAt, false);
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			context.setLastTypedProgram(frontend.typedProgram);
			for (name in frontend.moduleNames) {
				var state:ModuleState = candidate.modules.get(name);
				if (state.lastGood == null || state.lastGood.revision != state.revision) {
					state = context.writableState(name, snapshot.modules);
					state.captureLastGoodSnapshot();
				}
			}
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			compiler.adoptCandidate(candidate, generation);
			var diagnosticModules:Array<String> = [];
			for (name => state in candidate.modules) {
				var previous = snapshot.modules.get(name);
				if (previous == null || diagnosticFingerprint(previous.diagnostics) != diagnosticFingerprint(state.diagnostics))
					diagnosticModules.push(name);
			}
			diagnosticModules.sort(Reflect.compare);
			return {
				moduleNames: frontend.moduleNames,
				invalidatedModules: frontend.invalidatedModules,
				retyped: frontend.retyped,
				reusedClasses: frontend.reusedClasses,
				invalidatedArtifacts: frontend.invalidations,
				diagnosticModules: diagnosticModules,
				elapsedMs: Sys.time() * 1000.0 - startedAt
			};
		} catch (error:Dynamic) {
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			if (Std.isOfType(error, CancellationError))
				throw error;
			var failedDiagnostics:Map<String, Array<Diagnostic>> = [];
			for (name => state in candidate.modules)
				failedDiagnostics.set(name, state.diagnostics.copy());
			for (name => diagnostics in failedDiagnostics)
				if (compiler.modules.exists(name)) {
					var state:ModuleState = compiler.modules.get(name);
					state.diagnostics = diagnostics;
				}
			throw error;
		}
	}

	static function diagnosticFingerprint(diagnostics:Array<Diagnostic>):String
		return [
			for (diagnostic in diagnostics)
				diagnostic.code
				+ ":"
				+ Std.string(diagnostic.origin)
				+ ":"
				+ diagnostic.span.file.path
				+ ":"
				+ diagnostic.span.start
				+ ":"
				+ diagnostic.span.end
				+ ":"
				+ diagnostic.message].join("\n");
}
