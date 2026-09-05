package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

class Scope {
	final parent:Null<Scope>;
	final values:Map<String, CompilerType> = [];
	final captures:Map<String, Bool> = [];
	final cellCaptures:Map<String, Bool> = [];
	final cellClasses:Map<String, String> = [];

	public function new(?parent:Scope)
		this.parent = parent;

	public function define(name:String, type:CompilerType, span:SourceSpan):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		values.set(name, type);
	}

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String):Void {
		define(name, type, span);
		captures.set(name, true);
		if (cell) {
			cellCaptures.set(name, true);
			if (cellClass != null)
				cellClasses.set(name, cellClass);
		}
	}

	public function refine(name:String, type:CompilerType):Void {
		if (values.exists(name))
			values.set(name, type);
		else if (parent != null)
			values.set(name, type);
	}

	public function isCapture(name:String):Bool
		return captures.exists(name);

	public function isCellCapture(name:String):Bool
		return cellCaptures.exists(name);

	public function cellClass(name:String):Null<String>
		return cellClasses.get(name);

	public function resolve(name:String):Null<CompilerType> {
		var value = values.get(name);
		return value != null ? value : parent == null ? null : parent.resolve(name);
	}
}
