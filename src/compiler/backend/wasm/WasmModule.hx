package compiler.backend.wasm;

import haxe.io.Bytes;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmCompositeType;
import compiler.backend.wasm.WasmTypes.WasmSubtype;
import compiler.backend.wasm.WasmTypes.WasmTypeGroup;

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
	/** Type-section entries. Indices address the flattened subtype sequence across groups. */
	public final types:Array<WasmTypeGroup> = [];

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
		for (index in 0...typeCount()) {
			var candidate = typeAt(index);
			switch candidate.composite {
				case Func(functionType) if (sameType(functionType, type)):
					return index;
				default:
			}
		}
		return addType({finalType: true, supertypes: [], composite: Func(type)});
	}

	/** Adds one type and returns its flattened type index. */
	public function addType(type:WasmSubtype):Int {
		var index = typeCount();
		types.push(Single(type));
		return index;
	}

	/** Adds a mutually recursive type group and returns the index of its first type. */
	public function addRecGroup(group:Array<WasmSubtype>):Int {
		var index = typeCount();
		types.push(RecGroup(group));
		return index;
	}

	public function typeCount():Int {
		var count = 0;
		for (group in types)
			switch group {
				case Single(_):
					count++;
				case RecGroup(groupTypes):
					count += groupTypes.length;
			}
		return count;
	}

	public function typeAt(index:Int):WasmSubtype {
		if (index < 0)
			throw 'Unknown Wasm type index $index';
		var current = 0;
		for (group in types)
			switch group {
				case Single(type):
					if (current == index)
						return type;
					current++;
				case RecGroup(groupTypes):
					if (index < current + groupTypes.length)
						return groupTypes[index - current];
					current += groupTypes.length;
			}
		throw 'Unknown Wasm type index $index';
	}

	public function functionTypeAt(typeIndex:Int):WasmFunctionType {
		return switch typeAt(typeIndex).composite {
			case Func(type): type;
			default: throw 'Wasm type index $typeIndex does not identify a function type';
		};
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
			if (!sameValueType(left.parameters[index], right.parameters[index]))
				return false;
		for (index in 0...left.results.length)
			if (!sameValueType(left.results[index], right.results[index]))
				return false;
		return true;
	}

	function sameValueType(left:WasmValueType, right:WasmValueType):Bool {
		return switch [left, right] {
			case [I32, I32], [I64, I64], [F32, F32], [F64, F64]: true;
			case [Ref(leftType), Ref(rightType)]: leftType.nullable == rightType.nullable && sameHeapType(leftType.heap, rightType.heap);
			default: false;
		};
	}

	function sameHeapType(left:WasmTypes.WasmHeapType, right:WasmTypes.WasmHeapType):Bool {
		return switch [left, right] {
			case [Any, Any], [Eq, Eq], [I31, I31], [Struct, Struct], [Array, Array], [Func, Func], [Extern, Extern], [None, None], [NoExtern, NoExtern],
				[NoFunc, NoFunc], [Exn, Exn], [NoExn, NoExn]: true;
			case [Type(leftIndex), Type(rightIndex)]: leftIndex == rightIndex;
			default: false;
		};
	}
}
