package compiler.compilation;

import compiler.Diagnostic;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.service.CancellationError;
import compiler.service.CancellationToken;

/** Owns snapshot, rollback, and publication boundaries for one compilation. */
class CompilationTransaction {
	final compiler:Compiler;
	final entryModule:String;
	final token:Null<CancellationToken>;
	final startingAssembler:Null<HlModuleAssembler>;
	final indexSemantics:Bool;

	public function new(compiler:Compiler, entryModule:String, token:Null<CancellationToken>, startingAssembler:Null<HlModuleAssembler>,
			?indexSemantics = true) {
		this.compiler = compiler;
		this.entryModule = entryModule;
		this.token = token;
		this.startingAssembler = startingAssembler;
		this.indexSemantics = indexSemantics;
	}

	public function run():CompileResult {
		var transactionStartedAt = Sys.time() * 1000.0;
		compiler.publication.beforeCompile();
		var generation = compiler.currentSourceGeneration(),
			snapshot = compiler.snapshot();
		var snapshotDoneAt = Sys.time() * 1000.0;
		var previousAssembler = compiler.assembler;
		var candidate = compiler.createCandidate(snapshot, startingAssembler);
		if (!compiler.isSourceGenerationCurrent(generation))
			throw new CancellationError();
		try {
			var context = new CompilationContext(candidate, indexSemantics);
			var result = CompilationPipeline.compile(context, entryModule, token, snapshot.modules, transactionStartedAt, snapshotDoneAt, indexSemantics);
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			var abi = candidate.publishedAbi;
			if (abi == null)
				throw "Compilation did not produce a runtime ABI";
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			compiler.adoptCandidate(candidate);
			compiler.publication.candidate(result.revision, compiler.currentSourceGeneration(), abi, snapshot, previousAssembler);
			return result;
		} catch (error:Dynamic) {
			if (!compiler.isSourceGenerationCurrent(generation))
				throw new CancellationError();
			if (Std.isOfType(error, CancellationError))
				throw error;
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
