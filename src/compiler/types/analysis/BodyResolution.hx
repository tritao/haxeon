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

	/**
	 * The local at the root of a place a statement may write without assigning the local: a field assignment's object, a
	 * method call's receiver, an increment's target. Not a reference of the name; storage reads it (`StorageRequirements`).
	 */
	var PlaceWrite = 5;

	/** Like `PlaceWrite`, for the key of a `set` call whose receiver may be a key path (`pathTargetAt`). */
	var PathSet = 6;
}

/**
 * What a lambda sees of the names it does not declare (`free`: by the local a reference
 * names, the part before any dot; `freeAssigned`: those it assigns directly; `freeDeclarations`: the declaration of each
 * free local), and the declarations of its own it writes (`assigned`).
 */
typedef LambdaFacts = {
	free:Map<String, Bool>,
	freeAssigned:Map<String, Bool>,
	assigned:Map<String, Bool>,
	freeDeclarations:Map<String, String>
}

/** A lambda of a `BodyResolution`: its references `[first, end)`, its declarations, and how many lambdas enclose its body. */
typedef BodyLambda = {
	final first:Int;
	final end:Int;
	final firstDeclaration:Int;
	final endDeclaration:Int;
	final depth:Int;
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

	/** Whether the body, lambdas included, declares a scoped binding (`scoped var`), which `ScopedEscapeChecker` checks. */
	public var declaresScoped(default, null) = false;

	/** How many lambdas enclose each declaration. */
	public final declarationLambdaDepths:Array<Int> = [];

	// References, in walk order: the kind, two flags and the lambda depth packed in one Int, the name, the declaration and
	// the position.
	final codes:Array<Int> = [];

	public final names:Array<String> = [];
	public final declarations:Array<Int> = [];
	public final positions:Array<Int> = [];

	/** The method of a `MemberCall` or the operation of a `Receiver`, by reference. */
	final details:Map<Int, String> = [];

	/** The receiver of a `PathSet` and the declaration it names (-1 for none), by reference. */
	final pathTargets:Map<Int, {target:AstExpression, declaration:Int}> = [];

	/** The position of the lambda each local function is, by the declaration of its name. */
	final localFunctions:Map<Int, Int> = [];

	static inline final KIND_MASK = 7;

	/** The reference is in a lambda nested in its declaration's function or lambda. */
	public static inline final CAPTURED = 8;

	/** The reference is in its declaration's function or lambda, in a `try` body the declaration is outside of. */
	public static inline final DEEPER_TRY = 16;

	static inline final DEPTH_SHIFT = 5;

	function new() {}

	/** The resolution of a function with `arguments` and `body`. */
	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>,
			?outer:Map<String, String>):BodyResolution {
		var result = new BodyResolution();
		new BodyResolver(result).record(arguments, body, outer);
		return result;
	}

	/**
	 * How many declarations are not the body's own but the `outer` ones it was resolved within (`of`): syntax the typer
	 * builds is resolved where it is typed, so its names reach the locals visible there. They are the first ids.
	 */
	public var outerCount(default, null) = 0;

	/** Called while recording (`of`): the declarations before this one are outer. */
	public function recordOuter():Void
		outerCount = declarationKeys.length;

	/** The resolution of no syntax: where nothing declares a local, outside every body. */
	public static function empty():BodyResolution
		return new BodyResolution();

	/** The resolution of an expression typed on its own, as a field initializer is. */
	public static function ofExpression(expression:AstExpression):BodyResolution
		return of([], [Expression(expression, compiler.syntax.Parser.expressionSpan(expression))]);

	public var length(get, never):Int;

	inline function get_length():Int
		return codes.length;

	public inline function referenceAt(index:Int):BodyReference
		return cast(codes[index] & KIND_MASK);

	public inline function lambdaDepthAt(index:Int):Int
		return codes[index] >> DEPTH_SHIFT;

	/** Whether reference `index` has `flag` (`CAPTURED`, `DEEPER_TRY`). */
	public inline function hasFlag(index:Int, flag:Int):Bool
		return codes[index] & flag != 0;

	/** Of a `PathSet`. */
	public function pathTargetAt(index:Int):Null<{target:AstExpression, declaration:Int}>
		return pathTargets.get(index);

	/** The position of the lambda declaration `declaration` is a local function of, or null. */
	public function localFunctionAt(declaration:Int):Null<Int>
		return localFunctions.get(declaration);

	public inline function detailAt(index:Int):Null<String>
		return details.get(index);

	/** The declaration key (`BindingWalker.key`) of reference `index`'s declaration, or null when it names none. */
	public inline function keyAt(index:Int):Null<String> {
		var declaration = declarations[index];
		return declaration < 0 ? null : declarationKeys[declaration];
	}

	/** Called while recording (`of`); returns the declaration's id. */
	public function recordDeclaration(key:String, kind:BindingKind, type:Null<AstType>, initializer:Null<AstExpression>,
			lambdaDepth:Int):Int {
		declarationKeys.push(key);
		declarationLambdaDepths.push(lambdaDepth);
		declarationKinds.push(kind);
		declarationTypes.push(type);
		declarationInitializers.push(initializer);
		return declarationKeys.length - 1;
	}

	/** Called while recording (`of`): the `PathSet` just recorded has receiver `target`. */
	public function recordPathTarget(target:AstExpression, declaration:Int):Void
		pathTargets.set(codes.length - 1, {target: target, declaration: declaration});

	/** Called while recording (`of`). */
	public function recordScoped():Void
		declaresScoped = true;

	/** Called while recording (`of`). */
	public function recordLocalFunction(declaration:Int, lambdaPosition:Int):Void
		localFunctions.set(declaration, lambdaPosition);

	/** Called while recording (`of`). */
	public function recordReference(kind:BodyReference, name:String, declaration:Int, position:Int, detail:Null<String>,
			flags:Int, lambdaDepth:Int):Void {
		if (detail != null)
			details.set(codes.length, detail);
		codes.push((kind:Int) | flags | (lambdaDepth << DEPTH_SHIFT));
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
	 * in it included; null when the body has no such loop (syntax the typer built).
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
	final lambdas:Map<Int, BodyLambda> = [];

	/** The entries and declarations of the lambda at `position`, or null when the body has no such lambda. */
	public function lambdaAt(position:Int):Null<BodyLambda>
		return lambdas.get(position);

	/** Called while recording (`of`): the lambda at `position` holds the entries and declarations made since. */
	public function recordLambda(position:Int, first:Int, firstDeclaration:Int, depth:Int):Void
		lambdas.set(position, {
			first: first,
			end: codes.length,
			firstDeclaration: firstDeclaration,
			endDeclaration: declarationKeys.length,
			depth: depth
		});

	/**
	 * What the lambda at `position` sees of the names it does not declare (`free`: by the local a
	 * reference names, the part before any dot; `freeAssigned`: those it assigns directly), and the declarations of its own it
	 * writes; null when the body has no such lambda.
	 */
	public function lambdaFacts(position:Int):Null<LambdaFacts> {
		var lambda = lambdas.get(position);
		return lambda == null ? null : facts(lambda.first, lambda.end, lambda.firstDeclaration, lambda.endDeclaration);
	}

	/** `lambdaFacts` of the whole body, as a lambda the typer built and resolved within the locals around it is. */
	public function bodyFacts():LambdaFacts
		return facts(0, codes.length, outerCount, declarationKeys.length);

	/** The declarations the body assigns or increments, its own and the outer ones; a write to a field is no write of the local. */
	public function writes():Map<String, Bool> {
		var written:Map<String, Bool> = [];
		for (index in 0...codes.length)
			if (referenceAt(index) == Write && declarations[index] >= 0 && names[index].indexOf(".") < 0)
				written.set(declarationKeys[declarations[index]], true);
		return written;
	}

	function facts(first:Int, end:Int, firstDeclaration:Int, endDeclaration:Int):LambdaFacts {
		var lambda = {
			first: first,
			end: end,
			firstDeclaration: firstDeclaration,
			endDeclaration: endDeclaration
		};
		var free:Map<String, Bool> = [],
			freeAssigned:Map<String, Bool> = [],
			assigned:Map<String, Bool> = [],
			freeDeclarations:Map<String, String> = [];
		for (index in lambda.first...lambda.end) {
			var event = referenceAt(index);
			if (event == PlaceWrite || event == PathSet)
				continue;
			var declaration = declarations[index],
				name = names[index],
				own = declaration >= lambda.firstDeclaration && declaration < lambda.endDeclaration;
			if (!own) {
				free.set(BindingWalker.rootOf(name), true);
				if (declaration >= 0)
					freeDeclarations.set(BindingWalker.rootOf(name), declarationKeys[declaration]);
				if (event == Write && name.indexOf(".") < 0)
					freeAssigned.set(name, true);
			} else if (event == Write && name.indexOf(".") < 0)
				assigned.set(declarationKeys[declaration], true);
		}
		return {
			free: free,
			freeAssigned: freeAssigned,
			assigned: assigned,
			freeDeclarations: freeDeclarations
		};
	}

	/**
	 * The references `declarationAt` can find (all but place writes and path sets), sorted by position and, at one position,
	 * by recording order; made on first use.
	 */
	var byPosition:Null<Array<Int>> = null;

	/**
	 * The declaration key (`BindingWalker.key`) the reference to `name` at `position` resolves to: null when it names no local,
	 * and `UNSEEN` when the body has no such reference, as for syntax the typer builds itself. `a.b.c` is found by its root
	 * too, which is what a member chain's typing looks up; the latest reference at the position that matches wins.
	 */
	public function declarationAt(position:Int, name:String):Null<String> {
		var order = byPosition;
		if (order == null) {
			order = [];
			for (entry in 0...codes.length) {
				var kind = referenceAt(entry);
				if (kind != PlaceWrite && kind != PathSet)
					order.push(entry);
			}
			var at = positions;
			order.sort((left, right) -> at[left] != at[right] ? at[left] - at[right] : left - right);
			byPosition = order;
		}
		// The first sorted reference past `position`; the ones at it are just before, the latest last.
		var low = 0, high = order.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (positions[order[middle]] <= position)
				low = middle + 1;
			else
				high = middle;
		}
		var index = low - 1;
		while (index >= 0 && positions[order[index]] == position) {
			var entry = order[index], referenced = names[entry];
			if (referenced == name || referenced.length > name.length && referenced.charCodeAt(name.length) == ".".code
				&& StringTools.startsWith(referenced, name) && referenced.indexOf(".") == name.length)
				return keyAt(entry);
			index--;
		}
		return UNSEEN;
	}

	public static inline final UNSEEN = "$unseen";
}

/** Walks a body once and writes what `BindingWalker` tells it into a `BodyResolution`. */
private class BodyResolver extends BindingWalker {
	final bindings:BodyResolution;

	/** The id of each visible binding, beside the walker's stack of them. */
	final ids:Array<Int> = [];

	/** The `try` depth (`BindingWalker.tryDepth`) of each declaration, by id. */
	final declarationTryDepths:Array<Int> = [];

	public function new(bindings:BodyResolution) {
		super();
		this.bindings = bindings;
	}

	public function record(arguments:Array<AstArgument>, body:Array<AstStatement>,
			outer:Null<Map<String, String>>):Void {
		if (outer != null) {
			// Visible where the body is typed: declared before it, outside every lambda of it.
			for (name => declaration in outer) {
				bindings.recordDeclaration(declaration, Local, null, null, -1);
				ids.push(bindings.declarationKeys.length - 1);
				declarationTryDepths.push(0);
				bind(name, declaration);
			}
			bindings.recordOuter();
		}
		walkFunction(arguments, body);
	}

	/** The id of the binding the last `resolve` found, or -1. */
	inline function resolvedId():Int
		return resolvedIndex < 0 ? -1 : ids[resolvedIndex];

	/** Records a reference to the binding the last `resolve` found. */
	function add(kind:BodyReference, name:String, span:SourceSpan, ?detail:String):Void {
		var id = resolvedId(), flags = 0;
		if (id >= 0) {
			var depth = bindings.declarationLambdaDepths[id];
			if (lambdaDepth > depth)
				flags |= BodyResolution.CAPTURED;
			else if (tryDepth > declarationTryDepths[id])
				flags |= BodyResolution.DEEPER_TRY;
		}
		bindings.recordReference(kind, name, id, span.start, detail, flags, lambdaDepth);
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Void {
		ids.push(bindings.recordDeclaration(declaration, kind, type, initializer, lambdaDepth));
		declarationTryDepths.push(tryDepth);
	}

	override function leaveScope(height:Int):Void {
		super.leaveScope(height);
		ids.resize(height);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void
		add(Use, name, span);

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void
		add(Write, name, span);

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		add(Callee, name, span);

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void
		add(MemberCall, local, span, method);

	override function statement(value:AstStatement):Void
		switch value {
			case While(_, _, span), DoWhile(_, _, span), ForIn(_, _, _, _, span):
				var first = bindings.length;
				super.statement(value);
				bindings.recordLoop(span.start, first);
			case FieldAssignment(object, _, _, span):
				placeWrite(object, span);
				super.statement(value);
			case ScopedDeclaration(_, _, _, _):
				bindings.recordScoped();
				super.statement(value);
			case VarDeclaration(name, _, Lambda(_, _, _, lambdaSpan), span):
				super.statement(value);
				resolve(name);
				var id = resolvedId();
				if (id >= 0 && bindings.declarationKeys[id] == BindingWalker.key(name, span))
					bindings.recordLocalFunction(id, lambdaSpan.start);
			default:
				super.statement(value);
		}

	override function expression(value:AstExpression):Void {
		switch value {
			case MethodCall(target, "set", arguments, span) if (arguments.length == 2):
				pathSet(target, arguments[0], span);
			case Call(name, arguments, span) if (StringTools.endsWith(name, ".set") && arguments.length == 2):
				pathSet(Variable(name.substr(0, name.length - 4), span), arguments[0], span);
			default:
		}
		switch value {
			case PostfixIncrement(target, _, span), MethodCall(target, _, _, span):
				placeWrite(target, span);
			default:
		}
		switch value {
			case ArrayComprehension(_, _, _, _, _, _, span), MapComprehension(_, _, _, _, _, _, span):
				var first = bindings.length;
				super.expression(value);
				bindings.recordLoop(span.start, first);
			case Lambda(_, _, _, span):
				var first = bindings.length, firstDeclaration = bindings.declarationKeys.length;
				super.expression(value);
				bindings.recordLambda(span.start, first, firstDeclaration, lambdaDepth + 1);
			default:
				super.expression(value);
		}
	}

	override function receiver(target:AstExpression, operation:String):Void
		switch target {
			case Variable(name, span):
				resolve(name);
				add(Receiver, name, span, operation);
			default:
				expression(target);
		}

	/** The local at the root of `place`, a variable or a chain of fields of one, or null. */
	static function placeRoot(place:AstExpression):Null<String>
		return switch place {
			case Variable(name, _): BindingWalker.rootOf(name);
			case Member(parent, _, _): placeRoot(parent);
			default: null;
		};

	function placeWrite(place:AstExpression, span:SourceSpan):Void {
		var root = placeRoot(place);
		if (root != null && resolve(root) != null)
			add(PlaceWrite, root, span);
	}

	/** A `set` call on `target` with key `key`: whether it writes the key's root depends on what `target` is (`StorageRequirements`). */
	function pathSet(target:AstExpression, key:AstExpression, span:SourceSpan):Void {
		var root = placeRoot(key);
		if (root == null)
			return;
		var targetId = switch target {
			case Variable(name, _) if (name.indexOf(".") < 0):
				resolve(name);
				resolvedId();
			default: -1;
		};
		if (resolve(root) == null)
			return;
		add(PathSet, root, span);
		bindings.recordPathTarget(target, targetId);
	}
}
