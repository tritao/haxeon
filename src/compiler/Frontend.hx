package compiler;

import compiler.ir.Ir.IrProgram;
import compiler.ir.IrGenerator;
import compiler.types.Typer;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;

/** Stateless convenience pipeline from source text through typed SSA IR. */
class Frontend {
	public static function compile(source:String):IrProgram {
		return compileFile(new SourceFile("<memory>", source));
	}

	public static function compileFile(file:SourceFile):IrProgram {
		var ast = new Parser(new Lexer(file).tokenize()).parseProgram();
		return IrGenerator.generate(Typer.type(ast));
	}
}
