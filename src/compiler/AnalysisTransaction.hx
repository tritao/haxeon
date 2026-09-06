package compiler;

import compiler.Diagnostic;
import compiler.Compiler.AnalysisResult;
import compiler.modules.ModuleState;
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
		var snapshot = compiler.snapshot(),
			candidate = compiler.createCandidate(snapshot, null),
			startedAt = Sys.time() * 1000.0;
		try {
			var context = new CompilationContext(candidate);
			var frontend = FrontendCompilation.run(context, entryModule, token, snapshot.modules, startedAt);
			context.setLastTypedProgram(frontend.typedProgram);
			for (name in frontend.moduleNames) {
				var state = candidate.modules.get(name);
				if (state.lastGoodRevision != state.revision) {
					state = context.writableState(name, snapshot.modules);
					state.lastGoodTokens = state.tokens;
					state.lastGoodAst = state.ast;
					state.lastGoodSemanticModel = state.semanticModel;
					state.lastGoodSource = state.source;
					state.lastGoodRevision = state.revision;
				}
			}
			compiler.adoptCandidate(candidate);
			return {
				moduleNames: frontend.moduleNames,
				retyped: frontend.retyped,
				elapsedMs: Sys.time() * 1000.0 - startedAt
			};
		} catch (error:Dynamic) {
			var failedDiagnostics:Map<String, Array<Diagnostic>> = [];
			for (name => state in candidate.modules)
				failedDiagnostics.set(name, state.diagnostics.copy());
			for (name => diagnostics in failedDiagnostics)
				if (compiler.modules.exists(name))
					compiler.modules.get(name).diagnostics = diagnostics;
			throw error;
		}
	}
}
