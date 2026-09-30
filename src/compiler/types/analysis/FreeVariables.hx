package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
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

	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>):FreeVariables {
		var result = new FreeVariables();
		result.walkFunction(arguments, body);
		return result;
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
