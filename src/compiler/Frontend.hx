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
		var ast = new Parser(new Lexer(file).tokenizeTable()).parseProgram();
		// They are static fields of the module's class (ModuleFields), and this pipeline has no module.
		if (ast.fields != null && ast.fields.length > 0)
			throw new compiler.core.Diagnostic.CompileError(new compiler.core.Diagnostic("E0002",
				"Module-level variables need a module: compile them with compiler.Compiler", ast.fields[0].span));
		// The convenience frontend has no target; keep its IR portable.
		return IrProgramAssembler.generate(Typer.type(compiler.semantic.AbstractStatics.fold(ast)),
			TargetProfile.portable);
	}
}
