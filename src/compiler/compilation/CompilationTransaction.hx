package compiler.compilation;

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.core.CancellationToken;
import compiler.core.Diagnostic;

/** Owns snapshot, rollback, and publication boundaries for one compilation. */
class CompilationTransaction {
	final compiler:Compiler;
	final entryModule:String;
	final token:Null<CancellationToken>;
	final startingBackend:Null<BackendSession>;
	final indexSemantics:Bool;

	public function new(compiler:Compiler, entryModule:String, token:Null<CancellationToken>,
			startingBackend:Null<BackendSession>,
			?indexSemantics = true) {
		this.compiler = compiler;
		this.entryModule = entryModule;
		this.token = token;
		this.startingBackend = startingBackend;
		this.indexSemantics = indexSemantics;
	}

	public function run():CompileResult {
		var transactionStartedAt = Sys.time() * 1000.0;
		compiler.publication.beforeCompile();
		var snapshot = compiler.state;
		var snapshotDoneAt = Sys.time() * 1000.0;
		var candidate = compiler.createCandidate(startingBackend);
		try {
			var context = new CompilationContext(candidate, indexSemantics);
			var frontendStartedAt = Sys.time() * 1000.0;
			var result = CompilationPipeline.compile(context, entryModule, token, snapshot.modules,
				transactionStartedAt, snapshotDoneAt, frontendStartedAt,
				indexSemantics, compiler.publication.baseline());
			var abi = candidate.state.publishedAbi;
			if (abi == null)
				throw "Compilation did not produce a runtime ABI";
			compiler.adoptCandidate(candidate);
			if (result.unchanged)
				compiler.publication.unchanged(result.revision);
			else
				compiler.publication.candidate(result.revision, abi, snapshot);
			return result;
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
