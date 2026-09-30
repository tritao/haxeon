package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/**
 * Finds local maps that nothing else can reach, judged from source names alone.
 *
 * A call may remove an entry from any map it can reach, so flow facts about map entries do not survive calls. A local
 * map created in this function that is only ever used as the receiver of map operations cannot be reached from a
 * callee, so its facts are unaffected by calls. Anything unusual disqualifies a name: two declarations of it (also
 * through shadowing by a lambda, loop or catch variable), a parameter of the same name, a reassignment, or any use
 * other than as a map receiver, including every use inside a lambda.
 */
class MapEscapeAnalysis {
	static final MAP_OPERATIONS = ["get", "set", "exists", "remove", "clear", "keys", "size", "iterator", "copy"];

	final declarations:Map<String, Int> = [];
	final fresh:Map<String, Bool> = [];
	final escaped:Map<String, Bool> = [];

	function new() {}

	public static function privateMaps(statements:Array<AstStatement>, arguments:Array<String>):Map<String, Bool> {
		var state = new MapEscapeAnalysis();
		for (argument in arguments)
			state.declare(argument);
		scanStatements(statements, state, false);
		var result:Map<String, Bool> = [];
		for (name in state.fresh.keys())
			if (state.declarationCount(name) == 1 && !state.escaped.exists(name))
				result.set(name, true);
		return result;
	}

	function declarationCount(name:String):Int {
		var count = declarations.get(name);
		return count == null ? 0 : count;
	}

	function declare(name:String):Void
		declarations.set(name, declarationCount(name) + 1);

	function escape(name:String):Void
		escaped.set(name, true);

	static function scanStatements(statements:Array<AstStatement>, state:MapEscapeAnalysis, inLambda:Bool):Void {
		for (statement in statements)
			scanStatement(statement, state, inLambda);
	}

	static function scanStatement(statement:AstStatement, state:MapEscapeAnalysis, inLambda:Bool):Void {
		switch statement {
			case VarDeclaration(name, _, initializer, _):
				state.declare(name);
				if (createsMap(initializer))
					state.fresh.set(name, true);
				scanExpression(initializer, state, inLambda);
			case UninitializedDeclaration(name, _, _):
				state.declare(name);
			case Assignment(name, value, _):
				state.escape(root(name));
				scanExpression(value, state, inLambda);
			case Increment(name, _, _):
				state.escape(root(name));
			case IndexAssignment(receiver, key, value, _):
				scanReceiver(receiver, state, inLambda);
				scanExpression(key, state, inLambda);
				scanExpression(value, state, inLambda);
			case ForIn(name, valueName, iterable, body, _):
				state.declare(name);
				if (valueName != null)
					state.declare(valueName);
				scanReceiver(iterable, state, inLambda);
				scanStatements(body, state, inLambda);
			case If(test, yes, no, _):
				scanExpression(test, state, inLambda);
				scanStatements(yes, state, inLambda);
				scanStatements(no, state, inLambda);
			case While(test, body, _):
				scanExpression(test, state, inLambda);
				scanStatements(body, state, inLambda);
			case DoWhile(body, test, _):
				scanStatements(body, state, inLambda);
				scanExpression(test, state, inLambda);
			case Try(tryBranch, catches, _):
				scanStatements(tryBranch, state, inLambda);
				for (caught in catches) {
					state.declare(caught.name);
					scanStatements(caught.statements, state, inLambda);
				}
			case Switch(subject, cases, defaultBranch, _, _):
				scanExpression(subject, state, inLambda);
				for (entry in cases) {
					scanExpression(entry.value, state, inLambda);
					if (entry.guard != null)
						scanExpression(entry.guard, state, inLambda);
					scanStatements(entry.statements, state, inLambda);
				}
				scanStatements(defaultBranch, state, inLambda);
			default:
				for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
					scanExpression(expression, state, inLambda);
		}
	}

	/** A position where a map may appear without being handed to anyone else. */
	static function scanReceiver(expression:AstExpression, state:MapEscapeAnalysis, inLambda:Bool):Void {
		switch expression {
			case Variable(_, _) if (!inLambda):
			default:
				scanExpression(expression, state, inLambda);
		}
	}

	static function scanExpression(expression:AstExpression, state:MapEscapeAnalysis, inLambda:Bool):Void {
		switch expression {
			case Variable(name, _):
				state.escape(root(name));
			case MethodCall(receiver, name, arguments, _) if (MAP_OPERATIONS.indexOf(name) >= 0):
				scanReceiver(receiver, state, inLambda);
				for (argument in arguments)
					scanExpression(argument, state, inLambda);
			case Call(name, arguments, _) if (name.indexOf(".") > 0):
				// `map.get(key)` parses as a call whose name starts with the receiver local.
				var dot = name.indexOf("."), method = name.substr(dot + 1);
				if (inLambda || method.indexOf(".") >= 0 || MAP_OPERATIONS.indexOf(method) < 0)
					state.escape(name.substr(0, dot));
				for (argument in arguments)
					scanExpression(argument, state, inLambda);
			case Index(receiver, key, _):
				scanReceiver(receiver, state, inLambda);
				scanExpression(key, state, inLambda);
			case Lambda(arguments, body, _):
				for (argument in arguments)
					state.declare(argument.name);
				scanStatements(body, state, true);
			case BlockExpression(statements, value, _):
				scanStatements(statements, state, inLambda);
				scanExpression(value, state, inLambda);
			case ArrayComprehension(keyName, valueName, _, _, _, _, _), MapComprehension(keyName, valueName, _, _, _, _, _):
				state.declare(keyName);
				if (valueName != null)
					state.declare(valueName);
				for (child in compiler.syntax.AstChildren.expressions(expression))
					scanExpression(child, state, inLambda);
			default:
				for (child in compiler.syntax.AstChildren.expressions(expression))
					scanExpression(child, state, inLambda);
		}
	}

	static function createsMap(initializer:AstExpression):Bool
		return switch initializer {
			case NewMap(_, _, _), MapLiteral(_, _): true;
			case New("Map", _, _), NewGeneric("Map", _, _, _): true;
			default: false;
		};

	/** `map.field` style names count as uses of `map`. */
	static function root(name:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? name : name.substr(0, dot);
	}
}
