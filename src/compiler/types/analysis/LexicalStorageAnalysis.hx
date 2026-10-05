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

	public static function analyze(statements:Array<AstStatement>, arguments:Array<AstArgument>):LexicalStorageRequirements {
		var first = new LexicalStorageAnalysis(null);
		first.walkFunction(arguments, statements);
		var storage = new LexicalStorageAnalysis(first.writtenDeclarations);
		storage.walkFunction(arguments, statements);
		return {mutableCaptures: storage.captures, exceptionCells: storage.exceptions};
	}

	/** Declarations assigned anywhere, found by the first pass. Null during that pass. */
	final knownWrites:Null<Map<String, Bool>>;

	final writtenDeclarations:Map<String, Bool> = [];
	final captures:Map<String, Bool> = [];
	final exceptions:Map<String, Bool> = [];
	final declaredInLambda:Map<String, Int> = [];
	final declaredInTry:Map<String, Int> = [];

	/** Local functions whose own body the walk is inside. */
	final enclosingFunctions:Array<String> = [];

	function new(knownWrites:Null<Map<String, Bool>>) {
		super();
		this.knownWrites = knownWrites;
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>):Void {
		declaredInLambda.set(declaration, lambdaDepth);
		declaredInTry.set(declaration, tryDepth);
	}

	override function statement(value:AstStatement):Void {
		var localFunction = switch value {
			case VarDeclaration(name, _, Lambda(_, _, _), span): key(name, span);
			default: null;
		};
		if (localFunction != null)
			enclosingFunctions.push(localFunction);
		super.statement(value);
		if (localFunction != null)
			enclosingFunctions.pop();
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
		if (declaration == null || name.indexOf(".") >= 0)
			return;
		writtenDeclarations.set(declaration, true);
		if (knownWrites != null && isCaptured(declaration))
			captures.set(declaration, true);
		if (knownWrites != null && tryDepth > tryDepthOf(declaration))
			exceptions.set(declaration, true);
	}

	/** A closure reads its callee/receiver binding even without a bare value use. */
	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void {
		read(declaration);
	}

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void {
		read(declaration);
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
