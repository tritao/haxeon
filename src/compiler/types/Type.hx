package compiler.types;

enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TVoid;
	TClass(name:String);
	TArray(element:CompilerType);
	TFunction(arguments:Array<CompilerType>, result:CompilerType);
}
