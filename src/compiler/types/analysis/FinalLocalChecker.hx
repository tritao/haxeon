package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

/** Check source binding identities before canonicalization erases declaration syntax. */
class FinalLocalChecker extends BindingWalker {
	final finals:Map<String, Bool>;

	function new(finals:Map<String, Bool>) {
		super();
		this.finals = finals;
	}

	public static function check(arguments:Array<AstArgument>, statements:Array<AstStatement>, finals:Map<String, Bool>):Void {
		new FinalLocalChecker(finals).walkFunction(arguments, statements);
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null && name.indexOf(".") < 0 && finals.exists(declaration))
			throw new CompileError(new Diagnostic("E1026", 'Cannot reassign final local "$name"', span));
	}
}
