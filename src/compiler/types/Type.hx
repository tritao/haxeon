package compiler.types;

/**
 * Canonical semantic types produced by type checking.
 *
 * Unlike {@code AstType}, every named type here has been resolved. Backend
 * lowering must preserve the distinctions represented by these constructors.
 */
enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TBytes;
	THlBytes;
	TDynamic;
	TNativeAbstract(name:String);
	TNever;
	TRange;
	TVoid;
	TClass(name:String);
	TInterface(name:String);
	TEnum(name:String, arguments:Array<CompilerType>);
	TNull;
	TNullable(element:CompilerType);
	TArray(element:CompilerType);
	TMap(key:CompilerType, value:CompilerType);
	TFunction(arguments:Array<CompilerType>, result:CompilerType);
	TAnonymous(name:String, fields:Array<AnonymousField>);
}

/** Resolved field contract used to compare structural anonymous types. */
typedef AnonymousField = {final name:String; final type:CompilerType; final optional:Bool;}
