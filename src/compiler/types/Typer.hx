package compiler.types;

import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.typing.BodyTyper;
import compiler.types.typing.ProgramTyper;

typedef TyperPhaseMetrics = compiler.types.typing.TypingMetrics.TyperPhaseMetrics;
typedef MeasuredTypedProgram = compiler.types.typing.TypingMetrics.MeasuredTypedProgram;

/** Public entry points for semantic-to-typed-program conversion. */
class Typer {
	public static function type(program:AstProgram):TypedProgram
		return new ProgramTyper(new BodyTyper(null, null)).typeProgramMeasured(SemanticProgram.analyze(program), null, true, null).program;

	/** Type a reusable module without requiring an executable main function. */
	public static function typeLibrary(program:AstProgram):TypedProgram
		return new ProgramTyper(new BodyTyper(null, null)).typeProgramMeasured(SemanticProgram.analyze(program), null, false, null).program;

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzed(SemanticProgram.analyze(program), selected, externals, entryPoint);

	public static function typeAnalyzed(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String):TypedProgram
		return typeAnalyzedMeasured(semantic, selected, externals, entryPoint).program;

	public static function typeAnalyzedMeasured(semantic:SemanticProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>, ?entryPoint:String,
			?specializations:GenericSpecializationRegistry):MeasuredTypedProgram
		return new ProgramTyper(new BodyTyper(externals, specializations)).typeProgramMeasured(semantic, selected, true, entryPoint);
}
