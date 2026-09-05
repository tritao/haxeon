package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

class Scope {
	static var nextLocalId:Int = 0;

	final parent:Null<Scope>;
	final values:Map<String, {source:String, type:CompilerType, id:String}> = [];
	final captures:Map<String, Bool> = [];
	final cellCaptures:Map<String, Bool> = [];
	final cellClasses:Map<String, String> = [];

	public function new(?parent:Scope)
		this.parent = parent;

	public static function resetLocalIds():Void
		nextLocalId = 0;

	public function define(name:String, type:CompilerType, span:SourceSpan):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		values.set(name, {source: name, type: type, id: '$' + 'l${nextLocalId++}:$name'});
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
		if (values.exists(name)) {
			var local = values.get(name);
			values.set(name, {source: name, type: type, id: local.id});
			return;
		}
		for (sourceName => local in values)
			if (local.id == name) {
				values.set(sourceName, {source: sourceName, type: type, id: local.id});
				return;
			}
		if (parent != null) {
			var local = parent.resolveById(name);
			if (local != null)
				values.set(local.source, {source: local.source, type: type, id: local.id});
		}
	}

	public function isCapture(name:String):Bool
		return captures.exists(name);

	public function isCellCapture(name:String):Bool
		return cellCaptures.exists(name);

	public function cellClass(name:String):Null<String>
		return cellClasses.get(name);

	public function resolve(name:String):Null<CompilerType> {
		var value = values.get(name);
		return value != null ? value.type : parent == null ? null : parent.resolve(name);
	}

	public function resolveId(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.id;
	}

	function resolveLocal(name:String):Null<{source:String, type:CompilerType, id:String}> {
		var value = values.get(name);
		return value != null ? value : parent == null ? null : parent.resolveLocal(name);
	}

	function resolveById(id:String):Null<{source:String, type:CompilerType, id:String}> {
		for (value in values)
			if (value.id == id)
				return value;
		return parent == null ? null : parent.resolveById(id);
	}
}
