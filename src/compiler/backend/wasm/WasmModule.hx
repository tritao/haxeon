package compiler.backend.wasm;

import haxe.io.Bytes;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

typedef WasmDataSegment = {
	final offset:Int;
	final bytes:haxe.io.Bytes;
}

typedef WasmImport = {
	final module:String;
	final name:String;
	final type:WasmFunctionType;
}

typedef WasmLocal = {final type:WasmValueType;}

class WasmFunction {
	public final type:WasmFunctionType;
	public final locals:Array<WasmLocal>;
	public final body:Array<WasmInstruction>;
	public final name:String;

	public function new(name:String, type:WasmFunctionType, ?locals:Array<WasmLocal>, ?body:Array<WasmInstruction>) {
		this.name = name;
		this.type = type;
		this.locals = locals == null ? [] : locals;
		this.body = body == null ? [] : body;
	}
}

typedef WasmGlobal = {
	final type:WasmValueType;
	final mutable:Bool;
	final init:Array<WasmInstruction>;
}

typedef WasmExport = {
	final name:String;
	final functionIndex:Int;
}

typedef WasmCustomSection = {
	final name:String;
	final bytes:haxe.io.Bytes;
}

/** In-memory Wasm module, kept separate from Haxeon lowering and byte encoding. */
class WasmModule {
	public final types:Array<WasmFunctionType> = [];
	public final imports:Array<WasmImport> = [];
	public final functions:Array<WasmFunction> = [];
	public final globals:Array<WasmGlobal> = [];
	public final exports:Array<WasmExport> = [];
	public final data:Array<WasmDataSegment> = [];
	public final customSections:Array<WasmCustomSection> = [];
	public var start:Null<Int>;
	public var tableMin:Null<Int>;
	public final tableElements:Array<Int> = [];
	public var memoryMin:Null<Int>;
	public var importMemory:Bool;
	public var exceptionTagType:Null<Int>;
	public var exportMemory:Bool;
	public var exportTable:Bool;
	public var customName:Null<String>;

	public function new(?customName:String) {
		this.customName = customName;
		memoryMin = null;
		importMemory = false;
		exceptionTagType = null;
		exportMemory = false;
		exportTable = false;
		tableMin = null;
		start = null;
	}

	public function typeIndex(type:WasmFunctionType):Int {
		for (index in 0...types.length) {
			var candidate = types[index];
			if (sameType(candidate, type))
				return index;
		}
		types.push(type);
		return types.length - 1;
	}

	public function addFunction(fn:WasmFunction):Int {
		functions.push(fn);
		return imports.length + functions.length - 1;
	}

	public function addImport(module:String, name:String, type:WasmFunctionType):Int {
		imports.push({module: module, name: name, type: type});
		return imports.length - 1;
	}

	public function functionCount():Int
		return imports.length + functions.length;

	public function functionType(index:Int):WasmFunctionType {
		if (index < 0 || index >= functionCount())
			throw 'Unknown Wasm function index $index';
		return index < imports.length ? imports[index].type : functions[index - imports.length].type;
	}

	public function functionAt(index:Int):WasmFunction {
		if (index < imports.length || index >= functionCount())
			throw 'Wasm function index $index is not a defined function';
		return functions[index - imports.length];
	}

	public function setFunction(index:Int, fn:WasmFunction):Void {
		if (index < imports.length || index >= functionCount())
			throw 'Wasm function index $index is not a defined function';
		functions[index - imports.length] = fn;
	}

	function sameType(left:WasmFunctionType, right:WasmFunctionType):Bool {
		if (left.parameters.length != right.parameters.length || left.results.length != right.results.length)
			return false;
		for (index in 0...left.parameters.length)
			if (left.parameters[index] != right.parameters[index])
				return false;
		for (index in 0...left.results.length)
			if (left.results[index] != right.results[index])
				return false;
		return true;
	}
}
