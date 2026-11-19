package compiler.types.analysis;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.BindingWalker.BindingKind;

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
class MapEscapeAnalysis {
	public static final MAP_OPERATIONS = ["get", "set", "exists", "remove", "clear", "keys", "size", "iterator",
		"copy"];


	public static function analyze(arguments:Array<AstArgument>, body:Array<AstStatement>):MapPrivacy
		return fromResolution(BodyResolution.of(arguments, body));

	/** The same, read from a body's resolved names (`BodyResolution`) instead of walking it. */
	public static function fromResolution(resolution:BodyResolution):MapPrivacy {
		var count = resolution.declarationKeys.length,
			fresh = [for (_ in 0...count) false],
			escaped = [for (_ in 0...count) false],
			operandUses:Map<String, Bool> = [];
		for (id in 0...count) {
			var initializer = resolution.declarationInitializers[id];
			fresh[id] = resolution.declarationKinds[id] == BindingKind.Local && initializer != null
				&& (createsMap(initializer) || isEmptyLiteralOfMap(resolution.declarationTypes[id], initializer));
		}
		for (index in 0...resolution.length) {
			var declaration = resolution.declarations[index];
			if (declaration < 0)
				continue;
			var insideLambda = resolution.lambdaDepthAt(index) > 0;
			switch resolution.referenceAt(index) {
				case Use, Write, Callee:
					escaped[declaration] = true;
				case MemberCall:
					var method = resolution.detailAt(index) ?? "";
					if (method.indexOf(".") >= 0 || MAP_OPERATIONS.indexOf(method) < 0
						|| (insideLambda && removesEntries(method)))
						escaped[declaration] = true;
					else
						operandUses.set(BindingWalker.keyOf(resolution.names[index], resolution.positions[index]),
							true);
				case Receiver:
					if (insideLambda && removesEntries(resolution.detailAt(index) ?? ""))
						escaped[declaration] = true;
					else
						operandUses.set(BindingWalker.keyOf(resolution.names[index], resolution.positions[index]),
							true);
			}
		}
		// By key, as the walk decided: declarations that share a key are one.
		var freshKeys:Map<String, Bool> = [], escapedKeys:Map<String, Bool> = [];
		for (id in 0...count) {
			if (fresh[id])
				freshKeys.set(resolution.declarationKeys[id], true);
			if (escaped[id])
				escapedKeys.set(resolution.declarationKeys[id], true);
		}
		var privateDeclarations:Map<String, Bool> = [];
		for (key in freshKeys.keys())
			if (!escapedKeys.exists(key))
				privateDeclarations.set(key, true);
		return new MapPrivacy(privateDeclarations, operandUses);
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
