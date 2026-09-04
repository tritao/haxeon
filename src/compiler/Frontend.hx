package compiler;

import compiler.ir.Ir.IrProgram;
import compiler.ir.IrGenerator;
import compiler.types.Typer;

class Frontend {
    public static function compile(source:String):IrProgram {
        var ast = new Parser(new Lexer(source).tokenize()).parseProgram();
        return IrGenerator.generate(Typer.type(ast));
    }
}
