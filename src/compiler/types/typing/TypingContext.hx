package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.BindingStoragePlan;
import compiler.types.analysis.Scope;

/** Mutable state owned by one function or lambda while its body is checked. */
class TypingContext {
	public final functionName:String;
	/** Source function whose body is being typed; generated bodies keep their declaration identity. */
	public final sourceFunctionName:String;
	public final owner:Null<String>;
	public var name(get, never):String;
	public var lexicalOwner(get, never):Null<String>;
	public final typeSubstitutions:Map<String, CompilerType>;

	/**
	 * Warnings raised while typing this body and the lambdas written in it. They are kept with what the body becomes (a
	 * function or a field initializer), so a body reused unchanged by an incremental compile keeps them.
	 */
	public final warnings:Array<Diagnostic> = [];

	/** Declarations (see `BindingWalker.key`) the body assigns, including from lambdas: they may need a cell to be captured. */
	public final assignedDeclarations:Map<String, Bool> = [];

	/** The function's root lexical scope and resolved receiver, when it has one. */
	public var scope:Null<Scope>;

	public var receiver:Null<CompilerType>;

	/**
	 * An instance field's initializer, or a lambda written in one: it may not read `this`, nor a member through it, as in Haxe
	 * ("Cannot access this or other member field in variable initialization").
	 */
	public var memberInitializer = false;

	/** Owns the transition from conservative names to resolved lexical IDs. */
	public final storage = new BindingStoragePlan();

	/** The type a block expression's result local (a try expression's) has: the type the block is expected to have. */
	public final resultLocalTypes:Map<String, CompilerType> = [];
	/** Scoped binding identities, used to reject conversions that erase their lifetime. */
	public final scopedBindings:Map<String, String> = [];
	public var enumInterfaceTemporary:Int = 0;
	public var nullableAbstractTemporary:Int = 0;
	public var nullableDefaultTemporary:Int = 0;
	public var arrayTakeTemporary:Int = 0;
	public var keyPathTemporary:Int = 0;
	public var diffTemporary:Int = 0;
	public var assignedValueTemporary:Int = 0;

	public var loopDepth:Int = 0;

	/** The patterns of `value.match(pattern)` being typed, which bind no names (`BodyTyper.declarePatternName`). */
	public final postfixMatchPatterns:Array<compiler.core.Source.SourceSpan> = [];

	/** Nesting depth of an explicit `@:privateAccess` expression or statement. */
	public var privateAccessDepth:Int = 0;

	public var expectedReturnType:CompilerType = TVoid;
	public var inferredResult:Null<CompilerType>;
	public var contextualVoidLambda:Bool = false;

	inline function get_name():String
		return functionName;

	inline function get_lexicalOwner():Null<String>
		return owner;

	public function new(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?lexicalOwner:String,
			?sourceFunctionName:String) {
		this.functionName = name;
		this.sourceFunctionName = sourceFunctionName == null ? name : sourceFunctionName;
		this.owner = lexicalOwner;
		this.typeSubstitutions = typeSubstitutions == null ? [] : typeSubstitutions;
	}
}
