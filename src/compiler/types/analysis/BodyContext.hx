package compiler.types.analysis;

import compiler.types.Type.CompilerType;

/** Mutable state owned by one function or lambda while its body is checked. */
class BodyContext {
	public final name:String;
	public final lexicalOwner:Null<String>;
	public final typeSubstitutions:Map<String, CompilerType>;
	public final assigned:Map<String, Bool> = [];

	/** Owns the transition from conservative names to resolved lexical IDs. */
	public final storage = new BindingStoragePlan();

	public final localExpectedTypes:Map<String, CompilerType> = [];
	public var loopDepth:Int = 0;
	public final loopEarlyExits:Array<Bool> = [];
	public var resultType:CompilerType = TVoid;
	public var inferredResult:Null<CompilerType>;
	public var contextualVoidLambda:Bool = false;

	public function new(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?lexicalOwner:String) {
		this.name = name;
		this.lexicalOwner = lexicalOwner;
		this.typeSubstitutions = typeSubstitutions == null ? [] : typeSubstitutions;
	}
}
