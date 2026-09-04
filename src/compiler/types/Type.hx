package compiler.types;

enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TVoid;
	TClass(name:String);
}
