package compiler.compilation;

import compiler.Compiler;
import compiler.Compiler.AnalysisResult;
import compiler.core.CancellationToken;
import compiler.core.Diagnostic;
import compiler.core.InternalError;
import compiler.modules.ModuleState;
import compiler.types.typing.TypingFailure;

/** Runs compiler analysis transactionally without assembling or publishing a runtime artifact. */
class AnalysisTransaction {
	final compiler:Compiler;
	final entryModule:String;
	final token:Null<CancellationToken>;

	/** Fail, as a build does, when the program has no executable entry point. */
	final requireEntry:Bool;

	/** Modules this analysis types beside the compiler's roots, whatever its entry reaches. */
	final roots:Array<String>;

	public function new(compiler:Compiler, entryModule:String, token:Null<CancellationToken>, requireEntry = false,
			?roots:Array<String>) {
		this.requireEntry = requireEntry;
		this.roots = roots ?? [];
		this.compiler = compiler;
		this.entryModule = entryModule;
		this.token = token;
	}

	public function run():AnalysisResult {
		var snapshot = compiler.state,
			candidate = snapshot.copyForCandidate(),
			startedAt = Sys.time() * 1000.0;
		// Diagnostics are cleared where the analysis will look: from the entry and the modules every entry includes.
		var diagnosticWork = [entryModule].concat(compiler.rootModules).concat(roots),
			diagnosticSeen:Map<String, Bool> = [],
			diagnosticCursor = 0;
		while (diagnosticCursor < diagnosticWork.length) {
			var name = diagnosticWork[diagnosticCursor++];
			if (diagnosticSeen.exists(name) || !candidate.modules.exists(name))
				continue;
			diagnosticSeen.set(name, true);
			var state:ModuleState = candidate.modules.get(name);
			state.diagnostics = [];
			for (dependency in state.dependencies)
				diagnosticWork.push(dependency);
		}
		try {
			var context = new CompilationContext(compiler, candidate, true, requireEntry);
			for (root in roots)
				if (context.rootModules.indexOf(root) < 0)
					context.rootModules.push(root);
			var frontend = FrontendCompilation.run(context, entryModule, token, snapshot.modules, startedAt, false);
			var typed = frontend.typedProgram;
			if (typed == null)
				throw new InternalError("An analysis keeps its typed program");
			candidate.lastTypedProgram = typed;
			for (name in frontend.moduleNames) {
				var state:ModuleState = candidate.modules.get(name);
				if (state.lastGoodRevision != state.revision) {
					state = candidate.writableState(name, snapshot.modules);
					state.lastGoodTokens = state.tokens;
					state.lastGoodAst = state.ast;
					state.lastGoodSemanticModel = state.semanticModel;
					state.lastGoodSource = state.source;
					state.lastGoodRevision = state.revision;
				}
			}
			compiler.adoptCandidate(candidate);
			var diagnosticModules:Array<String> = [];
			for (name => state in candidate.modules) {
				var previous = snapshot.modules.get(name);
				if (previous == null
					|| diagnosticFingerprint(previous.diagnostics) != diagnosticFingerprint(state.diagnostics))
					diagnosticModules.push(name);
			}
			diagnosticModules.sort(Reflect.compare);
			var namespaceUses:Array<compiler.semantic.AliasTable.ModuleNamespaceUse> = [];
			for (name in frontend.moduleNames) {
				var state:ModuleState = candidate.modules.get(name);
				for (use in state.canonicalNamespaceUses)
					namespaceUses.push(use);
			}
			return {
				moduleNames: frontend.moduleNames,
				retyped: frontend.retyped,
				diagnosticModules: diagnosticModules,
				elapsedMs: Sys.time() * 1000.0 - startedAt,
				unboundLocals: typed.unboundLocals,
				nonExceptionThrows: typed.nonExceptionThrows,
				moduleNamespaceUses: namespaceUses
			};
		} catch (error:haxe.Exception) {
			var failedDiagnostics:Map<String, Array<Diagnostic>> = [];
			for (name => state in candidate.modules)
				failedDiagnostics.set(name, state.diagnostics.copy());
			for (name => diagnostics in failedDiagnostics)
				if (compiler.modules.exists(name)) {
					var state:ModuleState = compiler.modules.get(name);
					state.diagnostics = diagnostics;
				}
			// A typing that recovered from failed bodies indexed the ones that typed (`FrontendCompilation.indexRecoveredTyping`):
			// a module the failed candidate parsed keeps that index as its recovered state, which the editor reads until the
			// next analysis, so it need not guess from syntax.
			if (Std.isOfType(error, TypingFailure)) {
				var failure:TypingFailure = cast error;
				for (name => candidateState in candidate.modules) {
					var state = compiler.modules.get(name),
						ast = candidateState.ast;
					if (failure.indexedModules.exists(name) && state != null && state.ast == null && ast != null
						&& candidateState.semanticModel != null
						&& candidateState.revision == state.revision) {
						state.recoveredAst = ast;
						state.recoveredTokens = candidateState.tokens;
						state.recoveredSemanticModel = candidateState.semanticModel;
					}
				}
			}
			throw error;
		}
	}

	static function diagnosticFingerprint(diagnostics:Array<Diagnostic>):String
		return [
			for (diagnostic in diagnostics)
				diagnostic.code
				+ ":"
				+ diagnostic.span.file.path
				+ ":"
				+ diagnostic.span.start
				+ ":"
				+ diagnostic.span.end
				+ ":"
				+ diagnostic.message
		].join("\n");
}
