package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/**
 * The names a lambda uses that it does not declare itself, and which of them it assigns. A name the lambda declares
 * only in one block is free everywhere else it appears, so this is decided by scope, not by whether the name is
 * declared anywhere in the body.
 */
class FreeVariables extends BindingWalker {
	/** Every free name the body reads, calls or writes, by the local it names (the part before any dot). */
	public final names:Map<String, Bool> = [];

	/** The free names the body assigns or increments directly. */
	public final assigned:Map<String, Bool> = [];

	/**
	 * The declaration keys of the free temporaries and declared locals the body reaches, by name: syntax the typer built
	 * names the locals outside it this way (`TemporaryVariable`, `DeclaredVariable`).
	 */
	public final declarations:Map<String, String> = [];

	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>):FreeVariables {
		var result = new FreeVariables();
		result.walkFunction(arguments, body);
		return result;
	}

	override function expression(value:AstExpression):Void {
		switch value {
			case TemporaryVariable(local, _) if (resolve(local.name) == null && local.declaration != null):
				declarations.set(local.name, local.declaration);
			case DeclaredVariable(name, declaration, _) if (resolve(name) == null):
				declarations.set(name, BindingWalker.keyOf(name, declaration));
			default:
		}
		super.expression(value);
	}

	override function statement(value:AstStatement):Void {
		switch value {
			case TemporaryAssignment(local, _, _) if (resolve(local.name) == null && local.declaration != null):
				declarations.set(local.name, local.declaration);
			case DeclaredAssignment(name, declaration, _, _) if (resolve(name) == null):
				declarations.set(name, BindingWalker.keyOf(name, declaration));
			default:
		}
		super.statement(value);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null)
			names.set(BindingWalker.rootOf(name), true);
	}

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		used(name, declaration, span);

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void
		used(local, declaration, span);

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null)
			return;
		names.set(BindingWalker.rootOf(name), true);
		if (name.indexOf(".") < 0)
			assigned.set(name, true);
	}
}
