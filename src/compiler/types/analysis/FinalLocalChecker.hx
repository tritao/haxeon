package compiler.types.analysis;

import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.BindingWalker.BindingKind;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;

/**
 * Rejects writes to the locals Haxe does not let a body write: final locals and named local functions (`function f() {}`, which
 * Haxe binds as a function, not a variable). It checks source binding identities before canonicalization erases declaration
 * syntax.
 */
class FinalLocalChecker extends BindingWalker {
	final finals:Map<String, Bool>;
	final functions:Map<String, Bool> = [];

	function new(finals:Map<String, Bool>) {
		super();
		this.finals = finals;
	}

	public static function check(arguments:Array<AstArgument>, statements:Array<AstStatement>,
			finals:Map<String, Bool>):Void {
		new FinalLocalChecker(finals).walkFunction(arguments, statements);
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Void
		switch initializer {
			case Lambda(_, _, _, _, _, true):
				functions.set(declaration, true);
			default:
		}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null || name.indexOf(".") >= 0)
			return;
		if (finals.exists(declaration))
			throw new CompileError(new Diagnostic(DiagnosticCode.READ_ONLY_BINDING,
				'Cannot reassign final local "$name"', span));
		if (functions.exists(declaration))
			throw new CompileError(new Diagnostic(DiagnosticCode.READ_ONLY_BINDING,
				'Cannot access function $name for writing', span));
	}
}
