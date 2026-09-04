package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

class Scope {
	final parent:Null<Scope>;
	final values:Map<String, CompilerType> = [];

	public function new(?parent:Scope)
		this.parent = parent;

	public function define(name:String, type:CompilerType, span:SourceSpan):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		values.set(name, type);
	}

	public function resolve(name:String):Null<CompilerType> {
		var value = values.get(name);
		return value != null ? value : parent == null ? null : parent.resolve(name);
	}
}
