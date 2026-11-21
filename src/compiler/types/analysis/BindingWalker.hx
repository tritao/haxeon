package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstChildren;

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
class BindingWalker implements AstChildVisitor {
	/**
	 * The visible bindings, innermost last: a name and the declaration it refers to. A scope is the height the stack had when
	 * it was entered, so entering and leaving one allocates nothing.
	 */
	final bindingNames:Array<String> = [];

	final bindingDeclarations:Array<String> = [];
	var lambdaDepth:Int = 0;

	/** How many `try` bodies of the innermost function or lambda enclose the walk; a lambda starts again from 0. */
	var tryDepth:Int = 0;

	function new() {}

	/** The identity of the declaration of `name` at `span`. */
	public static function key(name:String, span:SourceSpan):String
		return keyOf(name, span.start);

	/** `key` of a declaration at offset `start`. */
	public static inline function keyOf(name:String, start:Int):String
		return name + "@" + start;

	/**
	 * The local a declaration key (`key`) names. Names a running module sees, such as cell classes, use it rather than the key:
	 * the key's source offset moves whenever code above it changes.
	 */
	public static function nameOf(key:String):String
		return key.substring(0, key.lastIndexOf("@"));

	/** `map.field` style names refer to the local before the first dot. */
	public static function rootOf(name:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? name : name.substring(0, dot);
	}

	/** Whether the walk is inside a lambda body, which may run at any time. */
	function insideLambda():Bool
		return lambdaDepth > 0;

	/**
	 * The declaration a name refers to here, or null when it names something else (a field, function or type). A dotted name
	 * refers to the binding of its root, which is matched in place rather than cut out.
	 */
	function resolve(name:String):Null<String> {
		var dot = name.indexOf("."),
			rootLength = dot < 0 ? name.length : dot,
			index = bindingNames.length;
		while (index > 0) {
			index--;
			if (isRoot(bindingNames[index], name, rootLength)) {
				resolvedIndex = index;
				return bindingDeclarations[index];
			}
		}
		resolvedIndex = -1;
		return null;
	}

	/** Where in the visible bindings the last `resolve` found its name, or -1; a hook reads it for the name it was given. */
	var resolvedIndex = -1;

	static function isRoot(candidate:String, name:String, rootLength:Int):Bool {
		if (candidate.length != rootLength)
			return false;
		if (rootLength == name.length)
			return candidate == name;
		for (index in 0...rootLength)
			if (StringTools.fastCodeAt(candidate, index) != StringTools.fastCodeAt(name, index))
				return false;
		return true;
	}

	function declare(name:String, span:SourceSpan, kind:BindingKind, ?type:AstType, ?initializer:AstExpression):String {
		var declaration = key(name, span);
		bindingNames.push(name);
		bindingDeclarations.push(declaration);
		declared(name, declaration, kind, type, initializer);
		return declaration;
	}

	/** Makes a name visible as the given declaration without reporting a declaration, for a scope entered from outside. */
	function bind(name:String, declaration:String):Void {
		bindingNames.push(name);
		bindingDeclarations.push(declaration);
	}

	/** Enters a scope; pass the result to `leaveScope`. */
	inline function enterScope():Int
		return bindingNames.length;

	function leaveScope(height:Int):Void {
		bindingNames.resize(height);
		bindingDeclarations.resize(height);
	}

	/** A child expression found by `AstChildren.visit`. */
	public function visitChild(child:AstExpression):Void
		expression(child);

	// Hooks.

	function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Void {}

	/** A bare read of a name, resolved to its declaration, or null when it is not a local. */
	function used(name:String, declaration:Null<String>, span:SourceSpan):Void {}

	/** An assignment or increment of a name (or of a field of it). */
	function written(name:String, declaration:Null<String>, span:SourceSpan):Void {}

	/** A call of a plain name, which is a local when it resolves to one. */
	function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		used(name, declaration, span);

	/**
	 * A call of `local.method(...)` that the parser spelled as one dotted name, `name`, whose method follows the dot at `dot`.
	 * The method is cut out only by the hooks that read it.
	 */
	function memberCall(local:String, declaration:Null<String>, name:String, dot:Int, span:SourceSpan):Void
		used(local, declaration, span);

	/** An expression that is the target of a collection operation: a call receiver, an index, or a loop's iterable. */
	function receiver(target:AstExpression, operation:String):Void
		expression(target);

	// Walking.

	/** Walks a function: its parameters are declared first, and the body shares their scope. */
	function walkFunction(arguments:Array<AstArgument>, body:Array<AstStatement>):Void {
		for (argument in arguments)
			declare(argument.name, argument.span, Parameter, argument.type);
		for (argument in arguments)
			if (argument.defaultValue != null)
				expression(argument.defaultValue);
		for (statement in body)
			this.statement(statement);
	}

	function statements(list:Array<AstStatement>):Void {
		var scope = enterScope();
		for (entry in list)
			statement(entry);
		leaveScope(scope);
	}

	function statement(value:AstStatement):Void {
		switch value {
			case PrivateAccessStatement(inner, _):
				statement(inner);
			case VarDeclaration(name, type, initializer, span):
				switch initializer {
					case Lambda(_, _, _, _):
						// A local function can call itself, so its name is visible in its own body.
						declare(name, span, Local, type, initializer);
						expression(initializer);
					default:
						expression(initializer);
						declare(name, span, Local, type, initializer);
				}
			case ScopedDeclaration(name, type, initializer, span):
				expression(initializer);
				declare(name, span, Local, type, initializer);
			case UninitializedDeclaration(name, type, span):
				declare(name, span, Local, type);
			// A temporary the typer introduced is a local under its name, as the typer types it.
			case TemporaryDeclaration(local, type, initializer, span):
				expression(initializer);
				declare(local.name, span, Local, type, initializer);
			case TemporaryAssignment(local, expression, span):
				this.expression(expression);
				written(local.name, resolve(local.name), span);
			case DeclaredAssignment(name, _, expression, span):
				this.expression(expression);
				written(name, resolve(name), span);
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
				var scope = enterScope();
				for (entry in body)
					statement(entry);
				expression(test);
				leaveScope(scope);
			case ForIn(name, valueName, iterable, body, span):
				receiver(iterable, "iterator");
				var scope = enterScope();
				declare(name, span, Loop);
				if (valueName != null)
					declare(valueName, span, Loop);
				for (entry in body)
					statement(entry);
				leaveScope(scope);
			case Try(tryBranch, catches, _):
				tryDepth++;
				statements(tryBranch);
				tryDepth--;
				for (caught in catches) {
					var scope = enterScope();
					declare(caught.name, caught.span, Catch);
					for (entry in caught.statements)
						statement(entry);
					leaveScope(scope);
				}
			case Defer(body, _):
				statements(body);
			case Switch(subject, cases, defaultBranch, _, _):
				expression(subject);
				// The first pattern declares the case's names; the others bind the same names to its locals (`SwitchCaseTyper`).
				for (entry in cases) {
					var scope = enterScope();
					bindCasePatterns(entry.patterns, entry.span);
					if (entry.guard != null)
						expression(entry.guard);
					for (inner in entry.statements)
						statement(inner);
					leaveScope(scope);
				}
				statements(defaultBranch);
			default:
				AstChildren.visitStatement(value, this);
		}
	}

	function expression(value:AstExpression):Void
		descend(value);

	/** Walks the parts of an expression. Subclasses call this to continue after looking at one themselves. */
	function descend(value:AstExpression):Void {
		switch value {
			case Variable(name, span):
				used(name, resolve(name), span);
			case TemporaryVariable(local, span):
				used(local.name, resolve(local.name), span);
			case DeclaredVariable(name, _, span):
				used(name, resolve(name), span);
			case Call(name, arguments, span):
				var dot = name.indexOf(".");
				if (dot > 0) {
					// A local's root is its binding's name, already made.
					var declaration = resolve(name);
					memberCall(declaration == null ? name.substring(0, dot) : bindingNames[resolvedIndex], declaration,
						name, dot, span);
				} else
					callee(name, resolve(name), span);
				for (argument in arguments)
					expression(argument);
			case MethodCall(target, name, arguments, _):
				receiver(target, name);
				for (argument in arguments)
					expression(argument);
			case Extractor(read, inner, extractorSpan):
				// In a `.match` pattern, walked as an expression since it binds no names; `_` is the value being matched.
				extracted(read, extractorSpan);
				expression(inner);
			case Index(target, position, _):
				receiver(target, "get");
				expression(position);
			case PostfixIncrement(target, _, span):
				switch target {
					case Variable(name, _): written(name, resolve(name), span);
					default:
				}
				expression(target);
			case Lambda(arguments, body, _, _):
				lambdaDepth++;
				var scope = enterScope(), outerTryDepth = tryDepth;
				tryDepth = 0;
				walkFunction(arguments, body);
				tryDepth = outerTryDepth;
				leaveScope(scope);
				lambdaDepth--;
			case BlockExpression(body, result, _):
				var scope = enterScope();
				for (entry in body)
					statement(entry);
				expression(result);
				leaveScope(scope);
			case AssignmentValue(store, _):
				statement(store);
			case SwitchExpression(subject, cases, fallback, _):
				expression(subject);
				for (arm in cases) {
					var scope = enterScope();
					bindCasePatterns(arm.patterns, arm.span);
					if (arm.guard != null)
						expression(arm.guard);
					expression(arm.result);
					leaveScope(scope);
				}
				if (fallback != null)
					expression(fallback);
			case ArrayComprehension(keyName, valueName, iterable, test, result, _, span):
				receiver(iterable, "iterator");
				var scope = enterScope();
				declare(keyName, span, Comprehension);
				if (valueName != null)
					declare(valueName, span, Comprehension);
				if (test != null)
					expression(test);
				expression(result);
				leaveScope(scope);
			case MapComprehension(keyName, valueName, iterable, test, key, result, span):
				receiver(iterable, "iterator");
				var scope = enterScope();
				declare(keyName, span, Comprehension);
				if (valueName != null)
					declare(valueName, span, Comprehension);
				if (test != null)
					expression(test);
				expression(key);
				expression(result);
				leaveScope(scope);
			default:
				AstChildren.visit(value, this);
		}
	}

	/**
	 * The patterns of one case: the first declares the names the guard and body read; each other pattern is walked in a scope of
	 * its own, since its names are the first's locals once typed (`SwitchCaseTyper`).
	 */
	function bindCasePatterns(patterns:Array<AstExpression>, span:SourceSpan):Void
		for (index in 0...patterns.length)
			if (index == 0)
				bindPattern(patterns[0], span);
			else {
				var scope = enterScope();
				bindPattern(patterns[index], span);
				leaveScope(scope);
			}

	/** An extractor's expression, which reads the value being matched as `_` (`ExtractorPatterns`), declared at the extractor. */
	function extracted(value:AstExpression, span:SourceSpan):Void {
		var scope = enterScope();
		declare("_", span, Pattern);
		expression(value);
		leaveScope(scope);
	}

	/** Every name in a case pattern may bind a variable; naming too many is the safe error. */
	function bindPattern(pattern:AstExpression, span:SourceSpan):Void {
		switch pattern {
			case Variable(name, variableSpan):
				declare(name, variableSpan, Pattern);
			case TemporaryVariable(local, variableSpan):
				declare(local.name, variableSpan, Pattern);
			case Capture(name, inner, captureSpan):
				declare(name, captureSpan, Pattern);
				bindPattern(inner, span);
			case Extractor(expression, inner, extractorSpan):
				extracted(expression, extractorSpan);
				bindPattern(inner, span);
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
