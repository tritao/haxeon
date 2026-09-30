package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Why a name is bound. Only a `Local` can be initialized with a value of its own. */
enum BindingKind {
	Parameter;
	Local;
	Loop;
	Catch;
	Pattern;
	Comprehension;
}

/**
 * Walks a function body the way the typer scopes it and tells its subclass which declaration each name refers to.
 *
 * Analyses that look at source before typing must not decide by bare name: the same name can be declared again in a
 * sibling block, or shadowed by a loop, catch, lambda or pattern variable. Here every declaration has an identity,
 * `name@offset`, that the typer's own scopes reproduce from the declaration's name and span, and every use is resolved
 * to the innermost declaration visible at that point. Subclasses override the hooks and, to look at a construct in
 * context, `expression` and `statement`, calling the inherited version to keep walking.
 */
class BindingWalker {
	final environments:Array<Map<String, String>> = [[]];
	var lambdaDepth:Int = 0;

	/** How many `try` bodies of the function itself enclose the walk; a lambda's own `try` blocks are its own. */
	var tryDepth:Int = 0;

	function new() {}

	/** The identity of the declaration of `name` at `span`. */
	public static function key(name:String, span:SourceSpan):String
		return name + "@" + span.start;

	/** `map.field` style names refer to the local before the first dot. */
	public static function rootOf(name:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? name : name.substr(0, dot);
	}

	/** Whether the walk is inside a lambda body, which may run at any time. */
	function insideLambda():Bool
		return lambdaDepth > 0;

	/** The declaration a name refers to here, or null when it names something else (a field, function or type). */
	function resolve(name:String):Null<String> {
		var root = rootOf(name), index = environments.length;
		while (index > 0) {
			index--;
			var found = environments[index].get(root);
			if (found != null)
				return found;
		}
		return null;
	}

	function declare(name:String, span:SourceSpan, kind:BindingKind, ?type:AstType, ?initializer:AstExpression):String {
		var declaration = key(name, span);
		environments[environments.length - 1].set(name, declaration);
		declared(name, declaration, kind, type, initializer);
		return declaration;
	}

	/** Makes a name visible as the given declaration without reporting a declaration, for a scope entered from outside. */
	function bind(name:String, declaration:String):Void
		environments[environments.length - 1].set(name, declaration);

	function scoped(action:() -> Void):Void {
		environments.push([]);
		action();
		environments.pop();
	}

	// Hooks.

	function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {}

	/** A bare read of a name, resolved to its declaration, or null when it is not a local. */
	function used(name:String, declaration:Null<String>, span:SourceSpan):Void {}

	/** An assignment or increment of a name (or of a field of it). */
	function written(name:String, declaration:Null<String>, span:SourceSpan):Void {}

	/** A call of a plain name, which is a local when it resolves to one. */
	function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		used(name, declaration, span);

	/** A call of `local.method(...)` that the parser spelled as one dotted name. */
	function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void
		used(local, declaration, span);

	/** An expression that is the target of a collection operation: a call receiver, an index, or a loop's iterable. */
	function receiver(target:AstExpression, operation:String):Void
		expression(target);

	// Walking.

	/** Walks a function: its parameters are declared first, and the body shares their scope. */
	function walkFunction(arguments:Array<AstArgument>, body:Array<AstStatement>):Void {
		for (argument in arguments)
			declare(argument.name, argument.span, Parameter);
		for (argument in arguments)
			if (argument.defaultValue != null)
				expression(argument.defaultValue);
		for (statement in body)
			this.statement(statement);
	}

	function statements(list:Array<AstStatement>):Void
		scoped(() -> {
			for (entry in list)
				statement(entry);
		});

	function statement(value:AstStatement):Void {
		switch value {
			case VarDeclaration(name, type, initializer, span):
				switch initializer {
					case Lambda(_, _, _):
						// A local function can call itself, so its name is visible in its own body.
						declare(name, span, Local, type, initializer);
						expression(initializer);
					default:
						expression(initializer);
						declare(name, span, Local, type, initializer);
				}
			case UninitializedDeclaration(name, type, span):
				declare(name, span, Local, type);
			case Assignment(name, expression, span):
				this.expression(expression);
				written(name, resolve(name), span);
			case Increment(name, _, span):
				written(name, resolve(name), span);
			case IndexAssignment(target, position, expression, _):
				receiver(target, "set");
				this.expression(position);
				this.expression(expression);
			case If(test, yes, no, _):
				expression(test);
				statements(yes);
				statements(no);
			case While(test, body, _):
				expression(test);
				statements(body);
			case DoWhile(body, test, _):
				// The condition is typed in the body's scope, so it sees what the body declares.
				scoped(() -> {
					for (entry in body)
						statement(entry);
					expression(test);
				});
			case ForIn(name, valueName, iterable, body, span):
				receiver(iterable, "iterator");
				scoped(() -> {
					declare(name, span, Loop);
					if (valueName != null)
						declare(valueName, span, Loop);
					for (entry in body)
						statement(entry);
				});
			case Try(tryBranch, catches, _):
				if (lambdaDepth == 0)
					tryDepth++;
				statements(tryBranch);
				if (lambdaDepth == 0)
					tryDepth--;
				for (caught in catches)
					scoped(() -> {
						declare(caught.name, caught.span, Catch);
						for (entry in caught.statements)
							statement(entry);
					});
			case Switch(subject, cases, defaultBranch, _, _):
				expression(subject);
				for (entry in cases)
					scoped(() -> {
						bindPattern(entry.value, entry.span);
						if (entry.guard != null)
							expression(entry.guard);
						for (inner in entry.statements)
							statement(inner);
					});
				statements(defaultBranch);
			default:
				for (expression in compiler.syntax.AstChildren.statementExpressions(value))
					this.expression(expression);
		}
	}

	function expression(value:AstExpression):Void
		descend(value);

	/** Walks the parts of an expression. Subclasses call this to continue after looking at one themselves. */
	function descend(value:AstExpression):Void {
		switch value {
			case Variable(name, span):
				used(name, resolve(name), span);
			case Call(name, arguments, span):
				var dot = name.indexOf(".");
				if (dot > 0)
					memberCall(name.substr(0, dot), resolve(name), name.substr(dot + 1), span);
				else
					callee(name, resolve(name), span);
				for (argument in arguments)
					expression(argument);
			case MethodCall(target, name, arguments, _):
				receiver(target, name);
				for (argument in arguments)
					expression(argument);
			case Index(target, position, _):
				receiver(target, "get");
				expression(position);
			case PostfixIncrement(target, _, span):
				switch target {
					case Variable(name, _): written(name, resolve(name), span);
					default:
				}
				expression(target);
			case Lambda(arguments, body, _):
				lambdaDepth++;
				scoped(() -> walkFunction(arguments, body));
				lambdaDepth--;
			case BlockExpression(body, result, _):
				scoped(() -> {
					for (entry in body)
						statement(entry);
					expression(result);
				});
			case SwitchExpression(subject, cases, fallback, _):
				expression(subject);
				for (arm in cases)
					scoped(() -> {
						bindPattern(arm.value, arm.span);
						if (arm.guard != null)
							expression(arm.guard);
						expression(arm.result);
					});
				if (fallback != null)
					expression(fallback);
			case ArrayComprehension(keyName, valueName, iterable, test, result, _, span):
				receiver(iterable, "iterator");
				scoped(() -> {
					declare(keyName, span, Comprehension);
					if (valueName != null)
						declare(valueName, span, Comprehension);
					if (test != null)
						expression(test);
					expression(result);
				});
			case MapComprehension(keyName, valueName, iterable, test, key, result, span):
				receiver(iterable, "iterator");
				scoped(() -> {
					declare(keyName, span, Comprehension);
					if (valueName != null)
						declare(valueName, span, Comprehension);
					if (test != null)
						expression(test);
					expression(key);
					expression(result);
				});
			default:
				for (child in compiler.syntax.AstChildren.expressions(value))
					expression(child);
		}
	}

	/** Every name in a case pattern may bind a variable; naming too many is the safe error. */
	function bindPattern(pattern:AstExpression, span:SourceSpan):Void {
		switch pattern {
			case Variable(name, variableSpan):
				declare(name, variableSpan, Pattern);
			case Call(_, arguments, _), ArrayLiteral(arguments, _):
				for (argument in arguments)
					bindPattern(argument, span);
			case ObjectLiteral(fields, _):
				for (field in fields)
					bindPattern(field.value, span);
			case Or(left, right, _):
				bindPattern(left, span);
				bindPattern(right, span);
			default:
		}
	}
}
