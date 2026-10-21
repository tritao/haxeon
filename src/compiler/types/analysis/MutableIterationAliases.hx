package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;

/** A concrete iterable representation must not narrow mutable parameters or inferred local storage. */
class MutableIterationAliases extends BindingWalker {
	final reads:Array<Map<String, Bool>> = [];
	final dependencies:Map<String, Map<String, Bool>> = [];

	public static function ofFunction(fn:AstFunction):Map<String, Bool> {
		var walker = new MutableIterationAliases();
		walker.walkFunction(fn.arguments, fn.statements);
		var mutable = AssignedDeclarations.ofFunction(fn.arguments, fn.statements).declarations;
		// An inferred local can store the parameter inside an object/array, return it
		// from a closure, or pass that storage to another function. Keep the declared
		// protocol at these boundaries; only direct uses specialize concretely.
		for (sources in walker.dependencies)
			for (source in sources.keys())
				mutable.set(source, true);
		return mutable;
	}

	override function statement(statement:AstStatement):Void {
		switch statement {
			case VarDeclaration(name, null, _, span):
				var sources:Map<String, Bool> = [];
				reads.push(sources);
				super.statement(statement);
				reads.pop();
				dependencies.set(BindingWalker.key(name, span), sources);
			default:
				super.statement(statement);
		}
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null)
			for (sources in reads)
				sources.set(declaration, true);
	}
}
