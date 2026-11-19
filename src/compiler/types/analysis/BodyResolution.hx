package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.BindingWalker.BindingKind;

/** What one reference of `BodyResolution` is. */
enum abstract BodyReference(Int) to Int {
	/** A bare read of a name. */
	var Use = 0;

	/** An assignment or increment of a name, or of a field of it. */
	var Write = 1;

	/** A call of a plain name. */
	var Callee = 2;

	/** A call `local.method(...)` the parser spelled as one dotted name; its detail is the method. */
	var MemberCall = 3;

	/** A name that is the target of a collection operation (a call receiver, an index, a loop's iterable); its detail is it. */
	var Receiver = 4;
}

/**
 * A function body's names, resolved once (docs/design/BODY_RESOLUTION.md): its declarations, numbered from 0 in source
 * order, and every reference to a name in walk order, with the declaration it refers to (-1 for none: a field, function or
 * type) and the lambda depth it is at. Built by `BindingWalker`, the one implementation of the scoping rules.
 */
class BodyResolution {
	// Declarations, by id.
	public final declarationKeys:Array<String> = [];
	public final declarationKinds:Array<BindingKind> = [];
	public final declarationTypes:Array<Null<AstType>> = [];
	public final declarationInitializers:Array<Null<AstExpression>> = [];

	// References, in walk order: the kind and lambda depth packed in one Int, the name, the declaration and the position.
	final codes:Array<Int> = [];

	public final names:Array<String> = [];
	public final declarations:Array<Int> = [];
	public final positions:Array<Int> = [];

	/** The method of a `MemberCall` or the operation of a `Receiver`, by reference. */
	final details:Map<Int, String> = [];

	static inline final KIND_BITS = 3;

	function new() {}

	/** The resolution of a function with `arguments` and `body`. */
	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>):BodyResolution {
		var result = new BodyResolution();
		new BodyResolver(result).record(arguments, body);
		return result;
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return codes.length;

	public inline function referenceAt(index:Int):BodyReference
		return cast(codes[index] & ((1 << KIND_BITS) - 1));

	public inline function lambdaDepthAt(index:Int):Int
		return codes[index] >> KIND_BITS;

	public inline function detailAt(index:Int):Null<String>
		return details.get(index);

	/** The declaration key (`BindingWalker.key`) of reference `index`'s declaration, or null when it names none. */
	public inline function keyAt(index:Int):Null<String> {
		var declaration = declarations[index];
		return declaration < 0 ? null : declarationKeys[declaration];
	}

	/** Called while recording (`of`); returns the declaration's id. */
	public function recordDeclaration(key:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Int {
		declarationKeys.push(key);
		declarationKinds.push(kind);
		declarationTypes.push(type);
		declarationInitializers.push(initializer);
		return declarationKeys.length - 1;
	}

	/** Called while recording (`of`). */
	public function recordReference(kind:BodyReference, name:String, declaration:Int, position:Int, detail:Null<String>,
			lambdaDepth:Int):Void {
		if (detail != null)
			details.set(codes.length, detail);
		codes.push((kind:Int) | (lambdaDepth << KIND_BITS));
		names.push(name);
		declarations.push(declaration);
		positions.push(position);
	}

	/** Each loop's references, by the loop's position: `[first, end)` in the entries (`writesInLoop`). */
	final loopFirst:Map<Int, Int> = [];

	final loopEnd:Map<Int, Int> = [];

	/** Called while recording (`of`): the loop at `position` holds the entries from `first` to the last added. */
	public function recordLoop(position:Int, first:Int):Void {
		loopFirst.set(position, first);
		loopEnd.set(position, codes.length);
	}

	/**
	 * The declarations the loop at `position` (a `while`, `do`, `for` or comprehension) writes, by declaration key, lambdas
	 * in it included, as `AssignedDeclarations` finds them; null when the body has no such loop (syntax the typer built).
	 */
	public function writesInLoop(position:Int):Null<Map<String, Bool>> {
		var first = loopFirst.get(position), end = loopEnd.get(position);
		if (first == null || end == null)
			return null;
		var written:Map<String, Bool> = [];
		for (index in first...end)
			if (referenceAt(index) == Write && declarations[index] >= 0 && names[index].indexOf(".") < 0)
				written.set(declarationKeys[declarations[index]], true);
		return written;
	}

	/** Each lambda's entries and declarations, by the lambda's position (`lambdaFacts`). */
	final lambdas:Map<Int, {first:Int, end:Int, firstDeclaration:Int, endDeclaration:Int}> = [];

	/** Called while recording (`of`): the lambda at `position` holds the entries and declarations made since. */
	public function recordLambda(position:Int, first:Int, firstDeclaration:Int):Void
		lambdas.set(position, {
			first: first,
			end: codes.length,
			firstDeclaration: firstDeclaration,
			endDeclaration: declarationKeys.length
		});

	/**
	 * What the lambda at `position` sees of the names it does not declare, as `FreeVariables` finds them (`free`: by the local a
	 * reference names, the part before any dot; `freeAssigned`: those it assigns directly), and the declarations of its own it
	 * writes, as `AssignedDeclarations` finds them; null when the body has no such lambda.
	 */
	public function lambdaFacts(position:Int):Null<{
		free:Map<String, Bool>,
		freeAssigned:Map<String, Bool>,
		assigned:Map<String, Bool>
	}> {
		var lambda = lambdas.get(position);
		if (lambda == null)
			return null;
		var free:Map<String, Bool> = [], freeAssigned:Map<String, Bool> = [], assigned:Map<String, Bool> = [];
		for (index in lambda.first...lambda.end) {
			var event = referenceAt(index);
			var declaration = declarations[index],
				name = names[index],
				own = declaration >= lambda.firstDeclaration && declaration < lambda.endDeclaration;
			if (!own) {
				free.set(BindingWalker.rootOf(name), true);
				if (event == Write && name.indexOf(".") < 0)
					freeAssigned.set(name, true);
			} else if (event == Write && name.indexOf(".") < 0)
				assigned.set(declarationKeys[declaration], true);
		}
		return {free: free, freeAssigned: freeAssigned, assigned: assigned};
	}

	/** References by position and name (`declarationAt`), made on first use. */
	var byPosition:Null<Map<String, Int>> = null;

	/**
	 * The declaration key (`BindingWalker.key`) the reference to `name` at `position` resolves to: null when it names no local,
	 * and `UNSEEN` when the body has no such reference, as for syntax the typer builds itself.
	 */
	public function declarationAt(position:Int, name:String):Null<String> {
		var index = byPosition;
		if (index == null) {
			index = [];
			for (entry in 0...codes.length) {
				var name = names[entry], position = positions[entry];
				index.set(position + ":" + name, entry);
				// `a.b.c` resolves by its root, which is what a member chain's typing looks up.
				if (name.indexOf(".") > 0)
					index.set(position + ":" + BindingWalker.rootOf(name), entry);
			}
			byPosition = index;
		}
		var entry = index.get(position + ":" + name);
		return entry == null ? UNSEEN : keyAt(entry);
	}

	public static inline final UNSEEN = "$unseen";
}

/** Walks a body once and writes what `BindingWalker` tells it into a `BodyResolution`. */
private class BodyResolver extends BindingWalker {
	final bindings:BodyResolution;

	/** The id of each visible binding, beside the walker's stack of them. */
	final ids:Array<Int> = [];

	public function new(bindings:BodyResolution) {
		super();
		this.bindings = bindings;
	}

	public function record(arguments:Array<AstArgument>, body:Array<AstStatement>):Void
		walkFunction(arguments, body);

	/** The id of the binding the last `resolve` found, or -1. */
	inline function resolvedId():Int
		return resolvedIndex < 0 ? -1 : ids[resolvedIndex];

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Void
		ids.push(bindings.recordDeclaration(declaration, kind, type, initializer));

	override function leaveScope(height:Int):Void {
		super.leaveScope(height);
		ids.resize(height);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Use, name, resolvedId(), span.start, null, lambdaDepth);

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Write, name, resolvedId(), span.start, null, lambdaDepth);

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Callee, name, resolvedId(), span.start, null, lambdaDepth);

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void
		bindings.recordReference(MemberCall, local, resolvedId(), span.start, method, lambdaDepth);

	override function statement(value:AstStatement):Void
		switch value {
			case While(_, _, span), DoWhile(_, _, span), ForIn(_, _, _, _, span):
				var first = bindings.length;
				super.statement(value);
				bindings.recordLoop(span.start, first);
			default:
				super.statement(value);
		}

	override function expression(value:AstExpression):Void
		switch value {
			case ArrayComprehension(_, _, _, _, _, _, span), MapComprehension(_, _, _, _, _, _, span):
				var first = bindings.length;
				super.expression(value);
				bindings.recordLoop(span.start, first);
			case Lambda(_, _, _, span):
				var first = bindings.length, firstDeclaration = bindings.declarationKeys.length;
				super.expression(value);
				bindings.recordLambda(span.start, first, firstDeclaration);
			default:
				super.expression(value);
		}

	override function receiver(target:AstExpression, operation:String):Void
		switch target {
			case Variable(name, span):
				resolve(name);
				bindings.recordReference(Receiver, name, resolvedId(), span.start, operation, lambdaDepth);
			default:
				expression(target);
		}
}
