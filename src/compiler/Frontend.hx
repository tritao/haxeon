package compiler;

import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceFile;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.pipeline.IrProgramAssembler;
import compiler.ir.pipeline.TargetProfile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** Stateless convenience pipeline from source text through typed SSA IR. */
class Frontend {
	public static function compile(source:String):IrProgram {
		return compileFile(new SourceFile("<memory>", source));
	}

	public static function compileFile(file:SourceFile):IrProgram {
		var ast = new Parser(new Lexer(file).tokenizeTable()).parseProgram();
		// They are static fields of the module's class (ModuleFields), and this pipeline has no module.
		if (ast.fields != null && ast.fields.length > 0)
			throw new compiler.core.Diagnostic.CompileError(new compiler.core.Diagnostic(DiagnosticCode.SYNTAX_ERROR,
				"Module-level variables need a module: compile them with compiler.Compiler", ast.fields[0].span));
		// The convenience frontend has no target; keep its IR portable.
		return IrProgramAssembler.generate(Typer.type(compiler.semantic.TypeStatics.fold(ast)),
			TargetProfile.portable);
	}
}
