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
	TFunction(arguments:Array<CompilerType>, result:CompilerType);

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
}

/** Resolved field contract used to compare structural anonymous types. */
typedef AnonymousField = {final name:String; final type:CompilerType; final optional:Bool; final isFinal:Bool;}
