package compiler.types;

import compiler.types.DeclarationIndex.DeclarationId;

/** Kind of declaration referenced by an instantiated nominal type. */
enum abstract NominalKind(String) {
	var Class = "class";
	var Interface = "interface";
	var Enum = "enum";
	var NativeValue = "native-value";
}

/**
 * Canonical semantic types produced by type checking.
 *
 * Unlike {@code AstType}, every named type here has been resolved. Backend
 * lowering must preserve the distinctions represented by these constructors.
 */
enum CompilerType {
	TInt;
	TInt64;
	TBool;
	TFloat;
	TString;
	TBytes;
	THlBytes;
	TDynamic;
	TNativeAbstract(name:String);

	/** Fixed-width or target-defined scalar used only in native memory layouts. */
	TNativeScalar(abiName:String);

	TNever;
	TRange;
	TVoid;
	TTypeParameter(owner:DeclarationId, name:String);
	TAbstract(declaration:DeclarationId, arguments:Array<CompilerType>, representation:CompilerType);
	TInstance(kind:NominalKind, declaration:DeclarationId, arguments:Array<CompilerType>);
	TNull;
	TNullable(element:CompilerType);
	TArray(element:CompilerType);
	TIterator(element:CompilerType);
	TMap(key:CompilerType, value:CompilerType);
	/** Invariant stored-field reference; writable paths can be viewed as readable paths. */
	TKeyPath(root:CompilerType, value:CompilerType, writable:Bool);
	/**
	 * A function type. `optional` flags the arguments a call may omit, as Haxe's `TFun` does (`(?x:Int)->Void`); it may be
	 * shorter than `arguments`, an argument past its end being required, so `[]` is a type with no optional argument.
	 * `FunctionTypes` reads and compares the flags.
	 */
	TFunction(arguments:Array<CompilerType>, result:CompilerType, optional:Array<Bool>);

	/**
	 * A structural record type. The structure can contain itself: `typedef Tree = {children:Array<Tree>}` resolves to
	 * a value whose `children` element is this very constructor, sharing the same `fields` array. Such a type is
	 * named after its typedef (`SemanticSignature.recursiveAnonymousName`) rather than spelled from its fields.
	 *
	 * Any code that walks a type through `fields` must therefore stop when it meets a structure it is already inside:
	 * compare by pairs in progress (`TypeRelations.equals`), or remember the `fields` arrays already explored
	 * (`NativeLayout.containsNativeLayoutType`). Never stringify a `CompilerType` with `Std.string`; use
	 * `SemanticSignature.type`, which stops at the name.
	 */
	TAnonymous(name:String, fields:Array<AnonymousField>);

	/**
	 * A type the code fixes later than it declares it, as Haxe's monomorphs: `var list = []` is an `Array<TMonomorph>` until
	 * a `push` fills the variable. Only the typer makes and sees these; see `Monomorphs`.
	 */
	TMonomorph(cell:MonomorphCell);
}

/** A type variable: empty until the first use that fixes it fills it, then that type for good. */
class MonomorphCell {
	/** What this is the type of, as an error names it when nothing fixes it: `the type of local "x"`. */
	public final origin:String;

	public final span:compiler.core.Source.SourceSpan;

	public var bound:Null<CompilerType> = null;

	/**
	 * The type a later use expects of it (a return, a typed argument): the context values flowing into it are typed in, so
	 * `list.push({name: n})` types the object as that use's structure. It is not the variable's type: the first use that
	 * fixes it fills it, as in Haxe, and only one nothing fills takes its hint.
	 */
	public var hint:Null<CompilerType> = null;

	public function new(origin:String, span:compiler.core.Source.SourceSpan) {
		this.origin = origin;
		this.span = span;
	}
}

/** Resolved field contract used to compare structural anonymous types. */
typedef AnonymousField = {
	final name:String;
	final type:CompilerType;
	final optional:Bool;
	final isFinal:Bool;
}
