package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstStatement;

/**
 * The declarations a body assigns or increments, by declaration and not by name: writing a variable that shadows another
 * of the same name does not count as writing the other. Writes to a field of a local (`a.b = 1`) are not writes of the
 * local, and writes inside lambdas count, since they run whenever the lambda is called.
 */
class AssignedDeclarations extends BindingWalker {
	/** Declaration identities (see `BindingWalker.key`) that are written. */
	public final declarations:Map<String, Bool> = [];

	/** A whole function: its parameters and the locals its body declares. */
	public static function ofFunction(arguments:Array<AstArgument>, body:Array<AstStatement>):AssignedDeclarations {
		var result = new AssignedDeclarations();
		result.walkFunction(arguments, body);
		return result;
	}

	/** A whole function, read from its resolved names (`BodyResolution`) instead of walking it. */
	public static function fromResolution(resolution:BodyResolution):AssignedDeclarations {
		var result = new AssignedDeclarations();
		for (index in 0...resolution.length)
			if (resolution.referenceAt(index) == Write && resolution.declarations[index] >= 0
				&& resolution.names[index].indexOf(".") < 0)
				result.declarations.set(resolution.keyAt(index), true);
		return result;
	}

	/** Statements that run in a scope where `visible` locals (name to declaration) are already declared. */
	public static function within(statements:Array<AstStatement>, visible:Map<String, String>):AssignedDeclarations {
		var result = new AssignedDeclarations();
		for (name => declaration in visible)
			result.bind(name, declaration);
		for (statement in statements)
			result.statement(statement);
		return result;
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null && name.indexOf(".") < 0)
			declarations.set(declaration, true);
	}
}
