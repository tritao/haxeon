package compiler.backend.wasm;

import haxe.io.Bytes;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

typedef WasmDataSegment = {
	final offset:Int;
	final bytes:haxe.io.Bytes;
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
	public final functions:Array<WasmFunction> = [];
	public final globals:Array<WasmGlobal> = [];
	public final exports:Array<WasmExport> = [];
	public final data:Array<WasmDataSegment> = [];
	public final customSections:Array<WasmCustomSection> = [];
	public var tableMin:Null<Int>;
	public final tableElements:Array<Int> = [];
	public var memoryMin:Null<Int>;
	public var exceptionTagType:Null<Int>;
	public var exportMemory:Bool;
	public var customName:Null<String>;

	public function new(?customName:String) {
		this.customName = customName;
		memoryMin = null;
		exceptionTagType = null;
		exportMemory = false;
		tableMin = null;
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
		return functions.length - 1;
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
