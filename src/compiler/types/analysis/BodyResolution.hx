package compiler.types.analysis;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.BindingWalker.BindingKind;

/** What one entry of `BodyResolution` records. */
enum abstract BodyReference(Int) {
	/** A declaration: `declaration` is its id. */
	var Declare = 0;

	/** A bare read of a name. */
	var Use = 1;

	/** An assignment or increment of a name, or of a field of it. */
	var Write = 2;

	/** A call of a plain name. */
	var Callee = 3;

	/** A call `local.method(...)` the parser spelled as one dotted name; `detail` is the method. */
	var MemberCall = 4;

	/** A name that is the target of a collection operation (a call receiver, an index, a loop's iterable); `detail` is it. */
	var Receiver = 5;
}

/**
 * A function body's names, resolved once (docs/design/BODY_RESOLUTION.md): its declarations, numbered from 0 in source
 * order, and every reference to a name in walk order, with the declaration it refers to (-1 for none: a field, function or
 * type) and the lambda and `try` depth it is at. Built by `BindingWalker`, the one implementation of the scoping rules.
 */
class BodyResolution {
	// Declarations, by id.
	public final declarationKeys:Array<String> = [];
	public final declarationNames:Array<String> = [];
	public final declarationKinds:Array<BindingKind> = [];
	public final declarationTypes:Array<Null<AstType>> = [];
	public final declarationInitializers:Array<Null<AstExpression>> = [];

	// Entries, in walk order.
	public final events:Array<BodyReference> = [];
	public final names:Array<String> = [];
	public final declarations:Array<Int> = [];
	/** Where the reference is; a declaration's entry has none (its key has its offset). */
	public final spans:Array<Null<SourceSpan>> = [];
	public final details:Array<Null<String>> = [];
	public final lambdaDepths:Array<Int> = [];
	public final tryDepths:Array<Int> = [];

	function new() {}

	/** The bindings of a function with `arguments` and `body`. */
	public static function of(arguments:Array<AstArgument>, body:Array<AstStatement>):BodyResolution {
		var result = new BodyResolution();
		new BodyResolver(result).record(arguments, body);
		return result;
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return events.length;

	/** Each loop's references, by the loop's position: `[first, end)` in the entries (`writesInLoop`). */
	final loopFirst:Map<Int, Int> = [];

	final loopEnd:Map<Int, Int> = [];

	/** Called while recording (`of`): the loop at `position` holds the entries from `first` to the last added. */
	public function recordLoop(position:Int, first:Int):Void {
		loopFirst.set(position, first);
		loopEnd.set(position, events.length);
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
			if (events[index] == Write && declarations[index] >= 0 && names[index].indexOf(".") < 0)
				written.set(declarationKeys[declarations[index]], true);
		return written;
	}

	/** Each lambda's entries and declarations, by the lambda's position (`lambdaFacts`). */
	final lambdas:Map<Int, {first:Int, end:Int, firstDeclaration:Int, endDeclaration:Int}> = [];

	/** Called while recording (`of`): the lambda at `position` holds the entries and declarations made since. */
	public function recordLambda(position:Int, first:Int, firstDeclaration:Int):Void
		lambdas.set(position, {
			first: first,
			end: events.length,
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
			var event = events[index];
			if (event == Declare)
				continue;
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
			for (entry in 0...events.length) {
				var span = spans[entry];
				if (events[entry] != Declare && span != null) {
					var name = names[entry];
					index.set(span.start + ":" + name, entry);
					// `a.b.c` resolves by its root, which is what a member chain's typing looks up.
					if (name.indexOf(".") > 0)
						index.set(span.start + ":" + BindingWalker.rootOf(name), entry);
				}
			}
			byPosition = index;
		}
		var entry = index.get(position + ":" + name);
		return entry == null ? UNSEEN : keyAt(entry);
	}

	public static inline final UNSEEN = "$unseen";

	/** The declaration key (`BindingWalker.key`) of entry `index`'s declaration, or null when it refers to none. */
	public inline function keyAt(index:Int):Null<String> {
		var declaration = declarations[index];
		return declaration < 0 ? null : declarationKeys[declaration];
	}

	function add(event:BodyReference, name:String, declaration:Int, span:Null<SourceSpan>, detail:Null<String>,
			lambdaDepth:Int, tryDepth:Int):Void {
		events.push(event);
		names.push(name);
		declarations.push(declaration);
		spans.push(span);
		details.push(detail);
		lambdaDepths.push(lambdaDepth);
		tryDepths.push(tryDepth);
	}

	function declare(name:String, key:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Int {
		var id = declarationKeys.length;
		declarationKeys.push(key);
		declarationNames.push(name);
		declarationKinds.push(kind);
		declarationTypes.push(type);
		declarationInitializers.push(initializer);
		return id;
	}

	/** Called while recording (`of`). */
	public function recordDeclaration(name:String, key:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>, lambdaDepth:Int, tryDepth:Int):Void
		add(Declare, name, declare(name, key, kind, type, initializer), null, null, lambdaDepth, tryDepth);

	/** Called while recording (`of`). */
	public function recordReference(event:BodyReference, name:String, declaration:Int, span:SourceSpan,
			detail:Null<String>,
			lambdaDepth:Int, tryDepth:Int):Void
		add(event, name, declaration, span, detail, lambdaDepth, tryDepth);
}

/** Walks a body once and writes what `BindingWalker` tells it into a `BodyResolution`. */
private class BodyResolver extends BindingWalker {
	final bindings:BodyResolution;

	/** Declaration keys to ids; a key names one declaration of the body. */
	final ids:Map<String, Int> = [];

	public function new(bindings:BodyResolution) {
		super();
		this.bindings = bindings;
	}

	public function record(arguments:Array<AstArgument>, body:Array<AstStatement>):Void
		walkFunction(arguments, body);

	function idOf(declaration:Null<String>):Int {
		if (declaration == null)
			return -1;
		var id = ids.get(declaration);
		return id == null ? -1 : id;
	}

	override function declared(name:String, declaration:String, kind:BindingKind, type:Null<AstType>,
			initializer:Null<AstExpression>):Void {
		ids.set(declaration, bindings.declarationKeys.length);
		bindings.recordDeclaration(name, declaration, kind, type, initializer, lambdaDepth, tryDepth);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Use, name, idOf(declaration), span, null, lambdaDepth, tryDepth);

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Write, name, idOf(declaration), span, null, lambdaDepth, tryDepth);

	override function callee(name:String, declaration:Null<String>, span:SourceSpan):Void
		bindings.recordReference(Callee, name, idOf(declaration), span, null, lambdaDepth, tryDepth);

	override function memberCall(local:String, declaration:Null<String>, method:String, span:SourceSpan):Void
		bindings.recordReference(MemberCall, local, idOf(declaration), span, method, lambdaDepth, tryDepth);

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
				bindings.recordReference(Receiver, name, idOf(resolve(name)), span, operation, lambdaDepth, tryDepth);
			default:
				expression(target);
		}
}
