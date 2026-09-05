package compiler.types;

enum CompilerType {
	TInt;
	TBool;
	TFloat;
	TString;
	TDynamic;
	TNever;
	TVoid;
	TClass(name:String);
	TInterface(name:String);
	TEnum(name:String);
	TNull;
	TNullable(element:CompilerType);
	TArray(element:CompilerType);
	TMap(key:CompilerType, value:CompilerType);
	TFunction(arguments:Array<CompilerType>, result:CompilerType);
	TAnonymous(name:String, fields:Array<AnonymousField>);
}

typedef AnonymousField = {final name:String; final type:CompilerType; final optional:Bool;}
