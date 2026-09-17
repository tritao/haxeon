package compiler.service;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.DiagnosticOrigin;
import compiler.Diagnostic.DiagnosticSeverity;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.semantic.SemanticModel;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.ConditionalCompilation.ConditionalSource;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.Token;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.RecoveryTypingModule;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.Type.CompilerType;

/** Operations that recovery delegates to the editor workspace. */
typedef RecoveryEngineHooks = {
	final editorDefines:Void->Map<String, String>;
	final typingModules:ModuleState->AstProgram->Null<CancellationToken>->Array<RecoveryTypingModule>;
	final reuseFunctions:ModuleState->AstProgram->Null<Map<String, Bool>>->Bool->Map<String, TypedFunction>;
	final resolveSymbol:ModuleState->AstProgram->String->Null<CancellationToken>->Null<SemanticSymbolId>;
	final resolveTypeSymbol:ModuleState->AstProgram->String->Null<CancellationToken>->Null<SemanticSymbolId>;
	final resolveEnumCase:ModuleState->AstProgram->String->Int->Null<CancellationToken>->Null<SemanticSymbolId>;
	final resolveType:ModuleState->AstProgram->String->Array<CompilerType>->Null<CancellationToken>->Null<CompilerType>;
	final symbolCandidates:ModuleState->String->Null<CancellationToken>->AstProgram->Array<SemanticSymbolId>;
	final publishDiagnostics:ModuleState->Array<Diagnostic>->Void;
}

/** Result of constructing one current-source recovered snapshot. */
typedef RecoveryEngineResult = {
	final published:Bool;
	final reusedFunctions:Int;
}

/**
	 * Builds editor-only syntax and partial semantic snapshots.
	 *
	 * The engine owns the recovery pipeline; workspace policy remains in the
	 * hooks so recovery cannot accidentally publish speculative declarations to
	 * the authoritative semantic workspace.
	 */
class RecoveryEngine {
	final hooks:RecoveryEngineHooks;

	public function new(hooks:RecoveryEngineHooks) {
		this.hooks = hooks;
	}

	public function recover(state:ModuleState, ?token:CancellationToken, ?externalChangedBodies:Map<String, Bool>,
		forceNoReuse:Bool = false):RecoveryEngineResult {
		var source = state.source,
			revision = state.revision;
		function isCurrent():Bool
			return state.source == source && state.revision == revision;

		function publish(diagnostics:Array<Diagnostic>):Void {
			if (!isCurrent())
				return;
			state.recoveryDiagnostics = diagnostics.copy();
			hooks.publishDiagnostics(state, diagnostics);
		}

		if (token != null)
			token.check();
		if (!isCurrent())
			return {published: false, reusedFunctions: 0};
		state.recoveryDiagnostics = [];

		var conditional:ConditionalSource;
		try
			conditional = ConditionalCompilation.process(state.source, hooks.editorDefines())
		catch (error:CompileError) {
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			state.conditionalDefines = [];
			error.diagnostic.origin = DiagnosticOrigin.ParserRecovery;
			publish([error.diagnostic]);
			return {published: false, reusedFunctions: 0};
		}
		if (!isCurrent())
			return {published: false, reusedFunctions: 0};

		var checkpoint:Null<Void->Void> = token == null ? null : function() token.check(),
			tokens:Array<Token>;
		try
			tokens = new Lexer(state.source, conditional.text, checkpoint).tokenize()
		catch (error:CompileError) {
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			error.diagnostic.origin = DiagnosticOrigin.Lexical;
			publish([error.diagnostic]);
			return {published: false, reusedFunctions: 0};
		}
		if (!isCurrent())
			return {published: false, reusedFunctions: 0};

		try {
			var recovered = new Parser(tokens, checkpoint).parseProgramRecovering(),
				inferredProgram = SignatureInference.inferProgram(recovered.program, checkpoint),
				recoveredModel = new SemanticModel(recovered.program, state.source, state.revision, tokens),
			typingDiagnostics:Array<Diagnostic> = [],
				typingModules = hooks.typingModules(state, recovered.program, token),
				reusedFunctions = hooks.reuseFunctions(state, recovered.program, externalChangedBodies, forceNoReuse);
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};

			recoveredModel.recoveredSignatureProgram = inferredProgram;
			var partialTypedProgram = Typer.typeRecovered(recovered.program, null, checkpoint, typingDiagnostics,
				typingModules, reusedFunctions, inferredProgram);
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			recoveredModel.partialTypedProgram = partialTypedProgram;
			for (module in typingModules)
				recoveredModel.indexRecoveredModule(module.program, module.declarations, module.qualifiers, token);
			var previousModel = state.previousEditorSemanticModel != null ? state.previousEditorSemanticModel
				: state.lastGood == null ? null : state.lastGood.semanticModel;
			recoveredModel.indexRecoveredSyntax(recovered.program, token, recoveredModel.partialTypedProgram,
				function(name) return hooks.resolveSymbol(state, recovered.program, name, token),
				function(name, index) return hooks.resolveEnumCase(state, recovered.program, name, index, token),
				function(name, arguments) return hooks.resolveType(state, recovered.program, name, arguments, token),
				function(name) return hooks.symbolCandidates(state, name, token, recovered.program),
				previousModel,
				function(name) return hooks.resolveTypeSymbol(state, recovered.program, name, token));
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			recoveredModel.freeze();
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			state.conditionalDefines = conditional.defines;
			state.publishRecoveredSnapshot(tokens, recovered.program, recoveredModel);
			publish(recovered.diagnostics.concat(typingDiagnostics));
			return {published: true, reusedFunctions: partialTypedProgram == null ? 0 : mapSize(reusedFunctions)};
		} catch (error:CompileError) {
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			error.diagnostic.origin = DiagnosticOrigin.ParserRecovery;
			// Keep the last-good semantic snapshot when recovery itself fails.
			publish([error.diagnostic]);
			return {published: false, reusedFunctions: 0};
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			if (!isCurrent())
				return {published: false, reusedFunctions: 0};
			// Unexpected recovery failures must not escape an editor update.
			publish([
				new Diagnostic("E0002", "Unable to recover editor syntax", state.source.span(0, 0), DiagnosticSeverity.Error, null,
					DiagnosticOrigin.ParserRecovery)
			]);
			return {published: false, reusedFunctions: 0};
		}
	}

	static function mapSize<T>(map:Map<String, T>):Int {
		var result = 0;
		for (_ in map)
			result++;
		return result;
	}
}
