package compiler.types;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.typing.BodyTyper;
import compiler.types.typing.ProgramTyper;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic;
import compiler.service.CancellationError;

typedef TyperPhaseMetrics = compiler.types.typing.TypingMetrics.TyperPhaseMetrics;
typedef MeasuredTypedProgram = compiler.types.typing.TypingMetrics.MeasuredTypedProgram;

/** Public entry points for semantic-to-typed-program conversion. */
class Typer {
	public static function type(program:AstProgram):TypedProgram
		return new ProgramTyper(new BodyTyper(null, null)).typeProgramMeasured(SemanticProgram.analyze(program), null, true, null).program;

	/** Type a reusable module without requiring an executable main function. */
	public static function typeLibrary(program:AstProgram, ?nativeAbiTarget:String):TypedProgram
		return new ProgramTyper(new BodyTyper(null, null, nativeAbiTarget)).typeProgramMeasured(SemanticProgram.analyze(program), null, false, null).program;

	/** Type a recovery tree while keeping failures local to the smallest body. */
	public static function typeRecovered(program:AstProgram, ?nativeAbiTarget:String, ?checkpoint:Void->Void,
			?diagnostics:Array<Diagnostic>):Null<TypedProgram> {
		var bodyTyper = new BodyTyper(null, null, nativeAbiTarget, true, checkpoint);
		try {
			var typed = new ProgramTyper(bodyTyper).typeProgramMeasured(SemanticProgram.analyzeRecovered(program), null, false, null).program;
			appendRecoveryDiagnostics(diagnostics, bodyTyper.recoveryDiagnostics());
			return typed;
		} catch (_:CompileError) {
			appendRecoveryDiagnostics(diagnostics, bodyTyper.recoveryDiagnostics());
			return null;
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			appendRecoveryDiagnostics(diagnostics, bodyTyper.recoveryDiagnostics());
			return null;
		}
	}

	static function appendRecoveryDiagnostics(target:Null<Array<Diagnostic>>, source:Array<Diagnostic>):Void {
		if (target == null)
			return;
		for (diagnostic in source) {
			var duplicate = false;
			for (existing in target)
				if (existing.code == diagnostic.code
					&& existing.span.file.path == diagnostic.span.file.path
					&& existing.span.start == diagnostic.span.start
					&& existing.span.end == diagnostic.span.end
					&& existing.message == diagnostic.message) {
					duplicate = true;
					break;
				}
			if (!duplicate)
				target.push(diagnostic);
		}
	}

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzed(SemanticProgram.analyze(program), selected, externals, entryPoint);

	public static function typeAnalyzed(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzedMeasured(semantic, selected, externals, entryPoint).program;

	public static function typeAnalyzedMeasured(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String, ?specializations:GenericSpecializationRegistry,
			?nativeAbiTarget:String):MeasuredTypedProgram
		return new ProgramTyper(new BodyTyper(externals, specializations, nativeAbiTarget)).typeProgramMeasured(semantic, selected, true, entryPoint);
}
