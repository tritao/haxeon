package compiler;

import compiler.core.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrProgramAssembler;
import compiler.ir.TargetProfile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** Stateless convenience pipeline from source text through typed SSA IR. */
class Frontend {
	public static function compile(source:String):IrProgram {
		return compileFile(new SourceFile("<memory>", source));
	}

	public static function compileFile(file:SourceFile):IrProgram {
		var ast = new Parser(new Lexer(file).tokenize()).parseProgram();
		// The convenience frontend has no target; keep its IR portable.
		return IrProgramAssembler.generate(Typer.type(ast), TargetProfile.portable);
	}
}
