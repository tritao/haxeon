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
	/** A recovered expression whose type is not known yet. */
	TUnknown;
	/** A recovered expression with a local typing failure. */
	TError;
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
	TAnonymous(name:String, fields:Array<AnonymousField>);
}

/** Resolved field contract used to compare structural anonymous types. */
typedef AnonymousField = {final name:String; final type:CompilerType; final optional:Bool;}
