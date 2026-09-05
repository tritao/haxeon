package compiler.types;

import compiler.types.Type.CompilerType;

/** Mutable state owned by one function or lambda while its body is checked. */
class BodyContext {
	public final name:String;
	public final assigned:Map<String, Bool> = [];
	public final cells:Map<String, String> = [];
	public final cellTypes:Map<String, CompilerType> = [];
	public var loopDepth:Int = 0;

	public function new(name:String)
		this.name = name;
}
