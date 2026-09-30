package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.BindingWalker.BindingKind;
import compiler.types.analysis.Scope.LocalFunction;

/**
 * What calling a closure can do to the locals of the function that created it: the outer variables its body
 * assigns, and whether it can run code this analysis cannot see.
 *
 * The typer forgets what it knew about a captured variable that is written somewhere whenever a closure is called,
 * because the call may assign it. When the closure called is known, a literal lambda called in place or a local
 * function that is never reassigned, only the variables its body (and the known local functions it reaches) assign
 * can change, so only those need forgetting. Anything else it might run leaves the effect `unknown`: a call through
 * a value of function type, a method or field call that may hold a closure, or a function-typed local it hands on.
 *
 * Only closures created in this function can assign its locals, so a function-typed parameter or a call of a
 * top-level function adds nothing. Closures that escape through objects are as invisible here as they are to any
 * other call the typer makes.
 */
class ClosureEffects extends BindingWalker {
	/** Source names of the outer variables the closure may assign. */
	public final writes:Map<String, Bool> = [];

	/** Whether the closure may run something whose writes are not known, so every captured variable must be forgotten. */
	public var unknown(default, null):Bool = false;

	final scope:Scope;
	final visited:Array<LocalFunction>;
	final lambdaDeclarations:Map<String, Bool> = [];

	/**
	 * `scope` is where the closure's free names resolve: the scope it was created in. `visited` holds the local
	 * functions already analysed, so a recursive one is analysed once.
	 */
	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>, scope:Scope, ?visited:Array<LocalFunction>):ClosureEffects {
		var effects = new ClosureEffects(scope, visited == null ? [] : visited);
		effects.lambdaDepth = 1;
		effects.walkFunction(arguments, body);
		return effects;
	}

	function new(scope:Scope, visited:Array<LocalFunction>) {
		super();
		this.scope = scope;
		this.visited = visited;
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {
		switch initializer {
			case Lambda(_, _, _):
				lambdaDeclarations.set(declaration, true);
			default:
		}
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null)
			writes.set(BindingWalker.rootOf(name), true);
		else if (lambdaDeclarations.exists(declaration))
			// A local function assigned a different function value is no longer the lambda it was declared with.
			unknown = true;
	}

	/** A call of a plain name: a local function value, or a top-level function that cannot touch locals. */
	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null) {
			// Declared inside the closure: its own lambda body is walked where it is declared, and anything
			// else (a parameter, a local holding a value) may be any function.
			if (!lambdaDeclarations.exists(declaration))
				unknown = true;
			return;
		}
		if (scope.resolve(name) != null)
			followLocal(name);
	}

	/** `local.member(...)` is a method call or a call of a function stored in a field; either may run a closure. */
	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		if (declaration != null || scope.resolve(local) != null)
			unknown = true;
	}

	/** A local function mentioned without being called can still be called by whatever receives it. */
	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null || name.indexOf(".") >= 0)
			return;
		var declared = scope.resolveDeclared(name);
		if (declared == null)
			return;
		if (scope.localFunction(name) != null)
			followLocal(name);
		else if (holdsFunction(declared))
			unknown = true;
	}

	override function expression(value:AstExpression):Void {
		switch value {
			case MethodCall(_, _, _, _):
				unknown = true;
			case ClosureCall(target, _, _):
				switch target {
					case Lambda(_, _, _):
					case Variable(name, span) if (name.indexOf(".") < 0): callee(name, resolve(name), span);
					default: unknown = true;
				}
			default:
		}
		descend(value);
	}

	/** Adds what the known local function `name` does, or marks the effect unknown when it is not one. */
	function followLocal(name:String):Void {
		var known = scope.localFunction(name);
		if (known == null) {
			unknown = true;
			return;
		}
		if (visited.indexOf(known) >= 0)
			return;
		visited.push(known);
		var inner = ClosureEffects.of(known.arguments, known.body, known.declaredIn == null ? scope : known.declaredIn, visited);
		for (written in inner.writes.keys())
			writes.set(written, true);
		if (inner.unknown)
			unknown = true;
	}

	static function holdsFunction(type:CompilerType):Bool
		return switch type {
			case TFunction(_, _): true;
			case TNullable(element), TArray(element): holdsFunction(element);
			case TMap(key, value): holdsFunction(key) || holdsFunction(value);
			default: false;
		};
}
