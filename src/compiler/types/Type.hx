package compiler.types;

enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TVoid;
	TClass(name:String);
	TInterface(name:String);
	TEnum(name:String);
	TNull;
	TNullable(element:CompilerType);
	TArray(element:CompilerType);
	TFunction(arguments:Array<CompilerType>, result:CompilerType);
}
