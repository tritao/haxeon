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

	override function receiver(target:AstExpression, operation:String):Void
		switch target {
			case Variable(name, span):
				bindings.recordReference(Receiver, name, idOf(resolve(name)), span, operation, lambdaDepth, tryDepth);
			default:
				expression(target);
		}
}
