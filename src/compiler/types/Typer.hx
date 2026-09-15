package compiler.types;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.typing.BodyTyper;
import compiler.types.typing.ProgramTyper;
import compiler.Diagnostic.CompileError;
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
	public static function typeRecovered(program:AstProgram, ?nativeAbiTarget:String, ?checkpoint:Void -> Void):Null<TypedProgram> {
		try {
			return new ProgramTyper(new BodyTyper(null, null, nativeAbiTarget, true, checkpoint))
				.typeProgramMeasured(SemanticProgram.analyze(program), null, false, null).program;
		} catch (_:CompileError) {
			return null;
		} catch (error:Dynamic) {
			if (Std.isOfType(error, CancellationError))
				throw error;
			return null;
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
