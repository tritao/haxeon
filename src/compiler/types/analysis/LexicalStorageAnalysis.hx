package compiler.types.analysis;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.BindingWalker.BindingKind;

typedef LexicalStorageRequirements = {
	final mutableCaptures:Map<String, Bool>;
	final exceptionCells:Map<String, Bool>;
	final closureWrites:Map<String, Bool>;
}

/**
 * Resolves storage requirements to declaration-site identities before typing.
 *
 * A local needs a cell when a lambda captures it and it is written somewhere, when a local function refers to itself,
 * or when it is written inside a `try` it was declared outside of, so the value survives the exception edge.
 */
class LexicalStorageAnalysis extends BindingWalker {
	public static function key(name:String, span:SourceSpan):String
		return BindingWalker.key(name, span);

	public static function analyze(statements:Array<AstStatement>, arguments:Array<AstArgument>,
			?mayHoldValue:(Null<AstType>, Null<AstExpression>)->Bool):LexicalStorageRequirements {
		var first = new LexicalStorageAnalysis(null, mayHoldValue);
		first.walkFunction(arguments, statements);
		var storage = new LexicalStorageAnalysis(first.writtenDeclarations, mayHoldValue);
		storage.walkFunction(arguments, statements);
		return {mutableCaptures: storage.captures, exceptionCells: storage.exceptions, closureWrites: storage.closureWrites};
	}

	/** Declarations assigned anywhere, found by the first pass. Null during that pass. */
	final knownWrites:Null<Map<String, Bool>>;

	final writtenDeclarations:Map<String, Bool> = [];
	final captures:Map<String, Bool> = [];
	final closureWrites:Map<String, Bool> = [];
	final exceptions:Map<String, Bool> = [];
	final declaredInLambda:Map<String, Int> = [];
	final declaredInTry:Map<String, Int> = [];
	final valueBindings:Map<String, Bool> = [];
	final bindingSyntax:Map<String, {type:Null<AstType>, initializer:Null<AstExpression>}> = [];
	final mayHoldValue:Null<(Null<AstType>, Null<AstExpression>)->Bool>;

	/** Local functions whose own body the walk is inside. */
	final enclosingFunctions:Array<String> = [];

	function new(knownWrites:Null<Map<String, Bool>>, mayHoldValue:Null<(Null<AstType>, Null<AstExpression>)->Bool>) {
		super();
		this.knownWrites = knownWrites;
		this.mayHoldValue = mayHoldValue;
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {
		declaredInLambda.set(declaration, lambdaDepth);
		declaredInTry.set(declaration, tryDepth);
		if (mayHoldValue != null) bindingSyntax.set(declaration, {type: type, initializer: initializer});
	}

	override function statement(value:AstStatement):Void {
		switch value {
			case FieldAssignment(object, _, _, span): writePlaceRoot(object, span);
			default:
		}
		var localFunction = switch value {
			case VarDeclaration(name, _, Lambda(_, _, _, _), span): key(name, span);
			default: null;
		};
		if (localFunction != null)
			enclosingFunctions.push(localFunction);
		super.statement(value);
		if (localFunction != null)
			enclosingFunctions.pop();
	}

	override function expression(value:AstExpression):Void {
		switch value {
			case PostfixIncrement(target, _, span): writePlaceRoot(target, span);
			case MethodCall(target, _, _, span): writePlaceRoot(target, span);
			default:
		}
		super.expression(value);
	}

	/** A value receiver's field or method may write the captured binding itself. Reference receivers are safe to
	 * conservatively put in a cell too; their identity and observable behavior stay the same. */
	function writePlaceRoot(value:AstExpression, span:SourceSpan):Void {
		switch value {
			case Variable(name, _):
				var root = BindingWalker.rootOf(name);
				var declaration = resolve(root);
				if (declaration != null && isValueBinding(declaration)) placeWritten(declaration);
			case Member(parent, _, _): writePlaceRoot(parent, span);
			default:
		}
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		read(declaration);
	}

	function read(declaration:Null<String>):Void {
		if (declaration == null)
			return;
		if (!refersToItself(declaration) && knownWrites != null && isCaptured(declaration) && knownWrites.exists(declaration))
			captures.set(declaration, true);
	}

	/** A local function that refers to itself, even by calling itself, lives in a cell that exists before the closure does. */
	function refersToItself(declaration:String):Bool {
		if (enclosingFunctions.indexOf(declaration) < 0 || !insideLambda())
			return false;
		captures.set(declaration, true);
		return true;
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration == null || (name.indexOf(".") >= 0 && !isValueBinding(declaration)))
			return;
		if (name.indexOf(".") >= 0) {
			placeWritten(declaration);
			return;
		}
		writtenDeclarations.set(declaration, true);
		if (knownWrites != null && isCaptured(declaration)) {
			captures.set(declaration, true);
			closureWrites.set(declaration, true);
		}
		if (knownWrites != null && tryDepth > tryDepthOf(declaration))
			exceptions.set(declaration, true);
	}

	/** A field write changes a captured value, but does not replace the local across an exception edge. */
	function placeWritten(declaration:String):Void {
		writtenDeclarations.set(declaration, true);
		if (knownWrites != null && isCaptured(declaration)) {
			captures.set(declaration, true);
			closureWrites.set(declaration, true);
		}
	}

	/** A closure reads its callee/receiver binding even without a bare value use. */
	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void {
		read(declaration);
	}

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		read(declaration);
		if (declaration != null && isValueBinding(declaration)) placeWritten(declaration);
	}

	function isValueBinding(declaration:String):Bool {
		if (mayHoldValue == null) return false;
		if (!valueBindings.exists(declaration)) {
			var syntax = bindingSyntax.get(declaration);
			valueBindings.set(declaration, syntax != null && mayHoldValue(syntax.type, syntax.initializer));
		}
		return valueBindings.get(declaration) == true;
	}

	function isCaptured(declaration:String):Bool
		return insideLambda() && lambdaDepth > lambdaDepthOf(declaration);

	function lambdaDepthOf(declaration:String):Int {
		var depth = declaredInLambda.get(declaration);
		return depth == null ? 0 : depth;
	}

	function tryDepthOf(declaration:String):Int {
		var depth = declaredInTry.get(declaration);
		return depth == null ? 0 : depth;
	}
}
