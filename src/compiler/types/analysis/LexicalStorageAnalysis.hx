package compiler.types.analysis;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

typedef LexicalStorageRequirements = {
	final mutableCaptures:Map<String, Bool>;
	final exceptionCells:Map<String, Bool>;
}

/** Resolves storage requirements to declaration-site identities before typing. */
class LexicalStorageAnalysis {
	public static function key(name:String, span:compiler.Source.SourceSpan):String
		return '$name@${span.start}';

	public static function analyze(statements:Array<AstStatement>, arguments:Array<AstArgument>):LexicalStorageRequirements {
		var environment:Map<String, String> = [];
		for (argument in arguments)
			environment.set(argument.name, key(argument.name, argument.span));
		var writes:Map<String, Bool> = [];
		walkStatements(statements, copy(environment), writes, null, null);
		var captures:Map<String, Bool> = [], exceptions:Map<String, Bool> = [];
		walkStatements(statements, copy(environment), writes, captures, exceptions);
		return {mutableCaptures: captures, exceptionCells: exceptions};
	}

	static function walkStatements(statements:Array<AstStatement>, environment:Map<String, String>, writes:Map<String, Bool>,
			captures:Null<Map<String, Bool>>, exceptions:Null<Map<String, Bool>>):Void {
		for (statement in statements) {
			for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
				walkExpression(expression, environment, writes, captures, exceptions, false);
			switch statement {
				case VarDeclaration(name, _, _, span), UninitializedDeclaration(name, _, span):
					environment.set(name, key(name, span));
				case Assignment(name, _, _), Increment(name, _, _):
					markWrite(name, environment, writes);
				case If(_, yes, no, _):
					walkStatements(yes, copy(environment), writes, captures, exceptions);
					walkStatements(no, copy(environment), writes, captures, exceptions);
				case While(_, body, _), DoWhile(body, _, _):
					walkStatements(body, copy(environment), writes, captures, exceptions);
				case ForIn(name, valueName, _, body, span):
					var loop = copy(environment);
					loop.set(name, key(name, span));
					if (valueName != null)
						loop.set(valueName, key(valueName, span));
					walkStatements(body, loop, writes, captures, exceptions);
				case Try(tryBranch, catches, _):
					if (exceptions != null) {
						var protectedWrites:Map<String, Bool> = [];
						walkStatements(tryBranch, copy(environment), protectedWrites, null, null);
						for (binding in protectedWrites.keys())
							if (containsValue(environment, binding))
								exceptions.set(binding, true);
					}
					walkStatements(tryBranch, copy(environment), writes, captures, exceptions);
					for (caught in catches) {
						var catchEnvironment = copy(environment);
						catchEnvironment.set(caught.name, key(caught.name, caught.span));
						walkStatements(caught.statements, catchEnvironment, writes, captures, exceptions);
					}
				case Switch(_, cases, fallback, _, _):
					for (entry in cases)
						walkStatements(entry.statements, copy(environment), writes, captures, exceptions);
					walkStatements(fallback, copy(environment), writes, captures, exceptions);
				default:
			}
		}
	}

	static function walkExpression(expression:AstExpression, environment:Map<String, String>, writes:Map<String, Bool>, captures:Null<Map<String, Bool>>,
			exceptions:Null<Map<String, Bool>>, insideLambda:Bool):Void {
		switch expression {
			case Variable(name, _):
				if (insideLambda && captures != null) {
					var binding = environment.get(root(name));
					if (binding != null && writes.exists(binding))
						captures.set(binding, true);
				}
			case PostfixIncrement(target, _, _):
				walkExpression(target, environment, writes, captures, exceptions, insideLambda);
				switch target {
					case Variable(name, _): markWrite(name, environment, writes);
					default:
				}
			case Lambda(arguments, body, _):
				var lambdaEnvironment = copy(environment);
				for (argument in arguments)
					lambdaEnvironment.set(argument.name, key(argument.name, argument.span));
				var nestedCaptures:Null<Map<String, Bool>> = captures == null ? null : [];
				walkStatementsInLambda(body, lambdaEnvironment, writes, nestedCaptures, exceptions);
				if (captures != null)
					for (binding in nestedCaptures.keys())
						if (containsValue(environment, binding))
							captures.set(binding, true);
			case BlockExpression(statements, value, _):
				var block = copy(environment);
				walkStatements(statements, block, writes, captures, exceptions);
				walkExpression(value, block, writes, captures, exceptions, insideLambda);
			default:
				for (child in compiler.syntax.AstChildren.expressions(expression))
					walkExpression(child, environment, writes, captures, exceptions, insideLambda);
		}
	}

	static function walkStatementsInLambda(statements:Array<AstStatement>, environment:Map<String, String>, writes:Map<String, Bool>,
			captures:Null<Map<String, Bool>>, exceptions:Null<Map<String, Bool>>):Void {
		for (statement in statements) {
			for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
				walkExpression(expression, environment, writes, captures, exceptions, true);
			switch statement {
				case VarDeclaration(name, _, _, span), UninitializedDeclaration(name, _, span):
					environment.set(name, key(name, span));
				case Assignment(name, _, _), Increment(name, _, _):
					markWrite(name, environment, writes);
					if (captures != null) {
						var binding = environment.get(root(name));
						if (binding != null)
							captures.set(binding, true);
					}
				case If(_, yes, no, _):
					walkStatementsInLambda(yes, copy(environment), writes, captures, exceptions);
					walkStatementsInLambda(no, copy(environment), writes, captures, exceptions);
				case While(_, body, _), DoWhile(body, _, _):
					walkStatementsInLambda(body, copy(environment), writes, captures, exceptions);
				case Try(yes, catches, _):
					walkStatementsInLambda(yes, copy(environment), writes, captures, exceptions);
					for (caught in catches) {
						var catchEnvironment = copy(environment);
						catchEnvironment.set(caught.name, key(caught.name, caught.span));
						walkStatementsInLambda(caught.statements, catchEnvironment, writes, captures, exceptions);
					}
				default:
			}
		}
	}

	static function markWrite(name:String, environment:Map<String, String>, writes:Map<String, Bool>):Void {
		if (name.indexOf(".") >= 0)
			return;
		var binding = environment.get(name);
		if (binding != null)
			writes.set(binding, true);
	}

	static function root(name:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? name : name.substring(0, dot);
	}

	static function copy(source:Map<String, String>):Map<String, String>
		return [for (name => binding in source) name => binding];

	static function containsValue(environment:Map<String, String>, expected:String):Bool {
		for (binding in environment)
			if (binding == expected)
				return true;
		return false;
	}
}
