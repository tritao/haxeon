package compiler.types;

import compiler.types.Type.CompilerType;

/** Mutable state owned by one function or lambda while its body is checked. */
class BodyContext {
	public final name:String;
	public final typeSubstitutions:Map<String, CompilerType>;
	public final assigned:Map<String, Bool> = [];
	public final cells:Map<String, String> = [];
	public final cellTypes:Map<String, CompilerType> = [];
	public final cellKinds:Map<String, compiler.types.TypedAst.CellStorageKind> = [];
	public var loopDepth:Int = 0;

	public function new(name:String, ?typeSubstitutions:Map<String, CompilerType>) {
		this.name = name;
		this.typeSubstitutions = typeSubstitutions == null ? [] : typeSubstitutions;
	}
}
