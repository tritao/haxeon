package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.BindingStoragePlan;
import compiler.types.analysis.Scope;

/** Mutable state owned by one function or lambda while its body is checked. */
class TypingContext {
	/** Whether this body is a unit's outermost, which records the unit's reads until it is left (`TypingSession.enterBody`). */
	public var recordsReads = false;

	/**
	 * The generated helper this body types (`TypingSession.enterHelperBody`), and how much the program had made besides helper
	 * requests when it began (`TypingSession.madeBesidesRequests`).
	 */
	public var helper:Null<String> = null;

	public var madeAtEntry = 0;

	public final functionName:String;
	/** Source function whose body is being typed; generated bodies keep their declaration identity. */
	public final sourceFunctionName:String;
	public final owner:Null<String>;
	public var name(get, never):String;
	public var lexicalOwner(get, never):Null<String>;
	public final typeSubstitutions:Map<String, CompilerType>;
	/**
	 * What the body's own types are in its code, where they are not themselves: a local generic function's erased types, or an
	 * elaborated generic body's specialization (`GenericElaboration`). The structures it registers, the lambdas it names and the
	 * generic calls it makes are of these types, as typing the body at them gives.
	 */
	public var localTypeRepresentation:Null<CompilerType->CompilerType> = null;

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

	/** The body's names as its resolver resolves them (`BodyResolution`); a lambda's are its function's. */
	public var resolution:Null<compiler.types.analysis.BodyResolution> = null;

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

	/** The switches with structure patterns being typed, by span, with the fields their tuples read (`StructurePatterns`). */
	public final structureSwitches:Array<{span:compiler.core.Source.SourceSpan, columns:Array<String>}> = [];

	/** The patterns of `value.match(pattern)` being typed, which bind no names (`BodyTyper.declarePatternName`). */
	public final postfixMatchPatterns:Array<compiler.core.Source.SourceSpan> = [];

	/** Nesting depth of an explicit `@:privateAccess` expression or statement. */
	public var privateAccessDepth:Int = 0;

	/** The null-safety mode the body is checked in (`NullSafety.enter`); a lambda's is its function's. */
	public var nullSafetyMode:compiler.NullSafetyRule.NullSafetyMode = Off;

	/** Whether the body's null-safety findings are warnings: its package's setting is `warn`. */
	public var nullSafetyWarns = false;

	/** Nesting depth of an expression or statement marked `@:nullSafety(Off)`, which is not checked. */
	public var nullSafetyOffDepth:Int = 0;

	/**
	 * Whether the body is a lambda, or is in one, that may run later than where it is written: a function value not passed
	 * straight to a call. Strict trusts no narrowing of a local it captures.
	 */
	public var nullSafetyClosure = false;

	/** Enters (`delta` 1) or leaves (-1) a statement or expression with `metadata` (`@:privateAccess`, `@:nullSafety(Off)`). */
	public function scopeMetadata(metadata:compiler.syntax.Ast.ScopeMetadata, delta:Int):Void
		switch metadata {
			case PrivateAccess:
				privateAccessDepth += delta;
			case NullSafetyOff:
				nullSafetyOffDepth += delta;
		}

	/** The scope of the expression being typed, whose flow facts the null-safety checker reads. */
	public var flowScope:Null<compiler.types.analysis.Scope> = null;

	/**
	 * The result the body's `return`s give, as its statements are typed against it (`typeStatements`), so a block or `try`
	 * inside an expression returns the same: null while a lambda's result is inferred from its returns (`inferredResult`).
	 */
	public var expectedReturnType:Null<CompilerType> = TVoid;
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
