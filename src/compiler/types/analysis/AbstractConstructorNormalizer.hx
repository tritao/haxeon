package compiler.types.analysis;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.syntax.Ast.AstCatch;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchCase;
import compiler.syntax.Ast.AstType;

/** Recasts an abstract constructor as an ordinary function returning its representation. */
class AbstractConstructorNormalizer {
	public static final RESULT_PREFIX = '$' + 'abstract-constructor-result';

	public static function normalize(constructor:AstFunction, representation:AstType):AstFunction {
		var resultName = uniqueResultName(constructor),
			statements = [UninitializedDeclaration(resultName, representation, constructor.span)];
		for (statement in constructor.statements)
			statements.push(rewriteStatement(statement, resultName));
		if (!alwaysExits(constructor.statements))
			statements.push(Return(Variable(resultName, constructor.span), constructor.span));
		return {
			name: constructor.name,
			isStatic: true,
			typeParameters: constructor.typeParameters == null ? [] : constructor.typeParameters,
			typeConstraints: constructor.typeConstraints,
			arguments: constructor.arguments,
			result: representation,
			statements: statements,
			span: constructor.span
		};
	}

	static function rewriteStatement(statement:AstStatement, resultName:String):AstStatement
		return switch statement {
			case Assignment("this", expression, span): Assignment(resultName, expression, span);
			case Return(_, span): throw new CompileError(new Diagnostic("E1003", "Abstract constructors cannot return a value", span));
			case ReturnVoid(span): Return(Variable(resultName, span), span);
			case If(predicate, yes, no, span):
				If(predicate, rewriteStatements(yes, resultName), rewriteStatements(no, resultName), span);
			case While(predicate, body, span): While(predicate, rewriteStatements(body, resultName), span);
			case DoWhile(body, predicate, span): DoWhile(rewriteStatements(body, resultName), predicate, span);
			case ForIn(key, value, iterable, body, span): ForIn(key, value, iterable, rewriteStatements(body, resultName), span);
			case Try(body, catches, span):
				Try(rewriteStatements(body, resultName), [for (entry in catches) rewriteCatch(entry, resultName)], span);
			case Switch(expression, cases, fallback, hasDefault, span):
				Switch(expression, [for (entry in cases) rewriteCase(entry, resultName)], rewriteStatements(fallback, resultName), hasDefault, span);
			default: statement;
		};

	static function rewriteStatements(statements:Array<AstStatement>, resultName:String):Array<AstStatement>
		return [for (statement in statements) rewriteStatement(statement, resultName)];

	static function rewriteCatch(entry:AstCatch, resultName:String):AstCatch
		return {
			name: entry.name,
			type: entry.type,
			statements: rewriteStatements(entry.statements, resultName),
			span: entry.span
		};

	static function rewriteCase(entry:AstSwitchCase, resultName:String):AstSwitchCase
		return {
			value: entry.value,
			guard: entry.guard,
			statements: rewriteStatements(entry.statements, resultName),
			span: entry.span
		};

	static function uniqueResultName(constructor:AstFunction):String {
		var used:Map<String, Bool> = [];
		for (argument in constructor.arguments)
			used.set(argument.name, true);
		collectDeclarations(constructor.statements, used);
		var name = RESULT_PREFIX, suffix = 0;
		while (used.exists(name)) {
			suffix++;
			name = '$' + 'abstract-constructor-result-$suffix';
		}
		return name;
	}

	static function collectDeclarations(statements:Array<AstStatement>, used:Map<String, Bool>):Void
		for (statement in statements)
			switch statement {
				case UninitializedDeclaration(name, _, _), VarDeclaration(name, _, _, _):
					used.set(name, true);
				case If(_, yes, no, _):
					collectDeclarations(yes, used);
					collectDeclarations(no, used);
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					collectDeclarations(body, used);
				case Try(body, catches, _):
					collectDeclarations(body, used);
					for (entry in catches)
						collectDeclarations(entry.statements, used);
				case Switch(_, cases, fallback, _, _):
					for (entry in cases)
						collectDeclarations(entry.statements, used);
					collectDeclarations(fallback, used);
				default:
			}

	static function alwaysExits(statements:Array<AstStatement>):Bool {
		for (statement in statements)
			if (statementAlwaysExits(statement))
				return true;
		return false;
	}

	static function statementAlwaysExits(statement:AstStatement):Bool
		return switch statement {
			case Return(_, _), ReturnVoid(_), Throw(_, _): true;
			case If(_, yes, no, _): no.length > 0 && alwaysExits(yes) && alwaysExits(no);
			case Try(body, catches, _):
				var exits = alwaysExits(body);
				for (entry in catches)
					if (!alwaysExits(entry.statements))
						exits = false;
				exits;
			case Switch(_, cases, fallback, hasDefault, _):
				var exits = hasDefault && alwaysExits(fallback);
				for (entry in cases)
					if (!alwaysExits(entry.statements))
						exits = false;
				exits;
			default: false;
		};
}
