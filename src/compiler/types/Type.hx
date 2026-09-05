package compiler.types;

enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TVoid;
	TClass(name:String);
	TFunction(arguments:Array<CompilerType>, result:CompilerType);
}
