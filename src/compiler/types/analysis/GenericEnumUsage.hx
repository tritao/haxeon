package compiler.types.analysis;

import compiler.syntax.Ast;
import compiler.types.analysis.BindingWalker.BindingKind;

/** Enum instances created only inside a shared body still need their semantic type arguments. */
class GenericEnumUsage extends BindingWalker {
	final test:AstType->Bool;
	var found = false;

	function new(test:AstType->Bool) {
		super();
		this.test = test;
	}

	public static function uses(fn:AstFunction, test:AstType->Bool):Bool {
		var scan = new GenericEnumUsage(test);
		scan.walkFunction(fn.arguments, fn.statements);
		return scan.found;
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {
		if (type != null && test(type)) found = true;
	}

	override function expression(value:AstExpression):Void {
		if (found) return;
		switch value {
			case Cast(_, target, _) if (target != null): if (test(target)) found = true;
			case NewGeneric(name, arguments, _, _): if (test(AppliedType(name, arguments))) found = true;
			case NewArray(element, _, _): if (test(element)) found = true;
			case NewMap(key, value, _): if (test(key) || test(value)) found = true;
			case NativeLayoutQuery(_, type, _, _): if (test(type)) found = true;
			default:
		}
		super.expression(value);
	}
}
