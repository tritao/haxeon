package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.analysis.BindingStoragePlan;
import compiler.types.analysis.Scope;

/** Mutable state owned by one function or lambda while its body is checked. */
class TypingContext {
	public final functionName:String;
	public final owner:Null<String>;
	public var name(get, never):String;
	public var lexicalOwner(get, never):Null<String>;
	public final typeSubstitutions:Map<String, CompilerType>;
	public final assigned:Map<String, Bool> = [];

	/** The function's root lexical scope and resolved receiver, when it has one. */
	public var scope:Null<Scope>;

	public var receiver:Null<CompilerType>;

	/** Owns the transition from conservative names to resolved lexical IDs. */
	public final storage = new BindingStoragePlan();

	public final localExpectedTypes:Map<String, CompilerType> = [];
	public var loopDepth:Int = 0;
	public final loopEarlyExits:Array<Bool> = [];
	public var expectedReturnType:CompilerType = TVoid;
	public var inferredResult:Null<CompilerType>;
	public var contextualVoidLambda:Bool = false;

	inline function get_name():String
		return functionName;

	inline function get_lexicalOwner():Null<String>
		return owner;

	public function new(name:String, ?typeSubstitutions:Map<String, CompilerType>, ?lexicalOwner:String) {
		this.functionName = name;
		this.owner = lexicalOwner;
		this.typeSubstitutions = typeSubstitutions == null ? [] : typeSubstitutions;
	}
}
