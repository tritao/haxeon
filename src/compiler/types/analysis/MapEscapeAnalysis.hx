package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.types.analysis.BindingWalker.BindingKind;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/**
 * Finds local maps that nothing else can reach.
 *
 * A call may remove an entry from any map it can reach, so flow facts about map entries do not survive calls. A local
 * map created in this function that is only ever used as the operand of map operations cannot be reached from a
 * callee, so its facts are unaffected by calls. Anything else disqualifies its declaration: a reassignment, or any use
 * other than as a map operand. A lambda, which may run at any time, may only use operations that cannot remove an
 * entry. Declarations are told apart by `BindingWalker`, so the same name in a sibling block, or shadowed by a loop or
 * lambda variable, is a different map.
 */
class MapEscapeAnalysis extends BindingWalker {
	public static final MAP_OPERATIONS = ["get", "set", "exists", "remove", "clear", "keys", "size", "iterator", "copy"];

	final fresh:Map<String, Bool> = [];
	final escaped:Map<String, Bool> = [];
	final operandUses:Map<String, Bool> = [];

	public static function analyze(arguments:Array<AstArgument>, body:Array<AstStatement>):MapPrivacy {
		var analysis = new MapEscapeAnalysis();
		analysis.walkFunction(arguments, body);
		var privateDeclarations:Map<String, Bool> = [];
		for (declaration in analysis.fresh.keys())
			if (!analysis.escaped.exists(declaration))
				privateDeclarations.set(declaration, true);
		return new MapPrivacy(privateDeclarations, analysis.operandUses);
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {
		if (kind == BindingKind.Local && initializer != null && (createsMap(initializer) || isEmptyLiteralOfMap(type, initializer)))
			fresh.set(declaration, true);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null)
			escaped.set(declaration, true);
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null)
			escaped.set(declaration, true);
	}

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		if (declaration == null)
			return;
		if (method.indexOf(".") >= 0 || MAP_OPERATIONS.indexOf(method) < 0 || (insideLambda() && removesEntries(method)))
			escaped.set(declaration, true);
		else
			operandUses.set(BindingWalker.key(local, span), true);
	}

	override function receiver(target:AstExpression, operation:String):Void {
		switch target {
			case Variable(name, span):
				var declaration = resolve(name);
				if (declaration == null)
					return;
				if (insideLambda() && removesEntries(operation))
					escaped.set(declaration, true);
				else
					operandUses.set(BindingWalker.key(name, span), true);
			default:
				expression(target);
		}
	}

	static function removesEntries(operation:String):Bool
		return operation == "remove" || operation == "clear";

	/** `var m:Map<K, V> = [];` is an empty map, not an array. */
	static function isEmptyLiteralOfMap(declared:Null<AstType>, initializer:AstExpression):Bool
		return switch initializer {
			case ArrayLiteral(values, _) if (values.length == 0): switch declared {
					case MapType(_, _): true;
					default: false;
				};
			default: false;
		};

	static function createsMap(initializer:AstExpression):Bool
		return switch initializer {
			case NewMap(_, _, _), MapLiteral(_, _): true;
			case New("Map", _, _), NewGeneric("Map", _, _, _): true;
			default: false;
		};
}
