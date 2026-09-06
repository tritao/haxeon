package compiler;

import compiler.Diagnostic;
import compiler.Compiler.CompileResult;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.service.CancellationToken;

/** Owns snapshot, rollback, and publication boundaries for one compilation. */
class CompilationTransaction {
	final compiler:Compiler;
	final entryModule:String;
	final token:Null<CancellationToken>;
	final startingAssembler:Null<HlModuleAssembler>;

	public function new(compiler:Compiler, entryModule:String, token:Null<CancellationToken>, startingAssembler:Null<HlModuleAssembler>) {
		this.compiler = compiler;
		this.entryModule = entryModule;
		this.token = token;
		this.startingAssembler = startingAssembler;
	}

	public function run():CompileResult {
		var transactionStartedAt = Sys.time() * 1000.0;
		compiler.publication.beforeCompile();
		var snapshot = compiler.snapshot();
		var snapshotDoneAt = Sys.time() * 1000.0;
		var previousAssembler = compiler.assembler;
		var candidate = compiler.createCandidate(snapshot, startingAssembler);
		try {
			var context = new CompilationContext(candidate);
			var result = CompilationPipeline.compile(context, entryModule, token, snapshot.modules, transactionStartedAt, snapshotDoneAt);
			var abi = candidate.publishedAbi;
			if (abi == null)
				throw "Compilation did not produce a runtime ABI";
			compiler.adoptCandidate(candidate);
			compiler.publication.candidate(result.revision, abi, snapshot, previousAssembler);
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
