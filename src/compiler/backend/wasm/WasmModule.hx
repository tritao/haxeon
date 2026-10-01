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

	/** Passive segments are not copied into memory; instructions such as `array.new_data` read them. */
	@:optional final passive:Bool;
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

	/**
	 * A body already in binary form (locals, code and its `end`), as linked from a precompiled module
	 * (WasmRuntimeLinker). Passes that rewrite instructions leave such a function alone.
	 */
	public final encodedBody:Null<haxe.io.Bytes>;

	public function new(name:String, type:WasmFunctionType, ?locals:Array<WasmLocal>, ?body:Array<WasmInstruction>, ?encodedBody:haxe.io.Bytes) {
		this.name = name;
		this.type = type;
		this.locals = locals == null ? [] : locals;
		this.body = body == null ? [] : body;
		this.encodedBody = encodedBody;
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

	/** `types` flattened by subtype index, and each function signature's first index; `types` is only appended to. */
	final flatTypes:Array<WasmSubtype> = [];

	final functionTypeIndices:Map<String, Int> = [];
	final standaloneFunctionTypeIndices:Map<String, Int> = [];
	var flattenedGroups = 0;

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
		flatten();
		var index = functionTypeIndices.get(functionTypeKey(type));
		return index != null ? index : addType({finalType: true, supertypes: [], composite: Func(type)});
	}

	/**
	 * The type an imported function is declared with: a final function type outside any recursion group.
	 * Wasm GC links a Wasm-exported function only to an import of the same canonical type, and a function
	 * type inside a recursion group is distinct from the same signature declared on its own, as every
	 * C function the host compiles is.
	 */
	public function importTypeIndex(type:WasmFunctionType):Int {
		flatten();
		var index = standaloneFunctionTypeIndices.get(functionTypeKey(type));
		return index != null ? index : addType({finalType: true, supertypes: [], composite: Func(type)});
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
		flatten();
		return flatTypes.length;
	}

	public function typeAt(index:Int):WasmSubtype {
		flatten();
		if (index < 0 || index >= flatTypes.length)
			throw 'Unknown Wasm type index $index';
		return flatTypes[index];
	}

	function flatten():Void
		while (flattenedGroups < types.length) {
			switch types[flattenedGroups++] {
				case Single(type):
					indexType(type, type.finalType && type.supertypes.length == 0);
				case RecGroup(groupTypes):
					for (type in groupTypes)
						indexType(type, false);
			}
		}

	function indexType(type:WasmSubtype, standalone:Bool):Void {
		switch type.composite {
			case Func(functionType):
				var key = functionTypeKey(functionType);
				if (!functionTypeIndices.exists(key))
					functionTypeIndices.set(key, flatTypes.length);
				if (standalone && !standaloneFunctionTypeIndices.exists(key))
					standaloneFunctionTypeIndices.set(key, flatTypes.length);
			default:
		}
		flatTypes.push(type);
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

	static function functionTypeKey(type:WasmFunctionType):String {
		var key = new StringBuf();
		for (parameter in type.parameters)
			key.add(valueTypeKey(parameter));
		key.add("->");
		for (result in type.results)
			key.add(valueTypeKey(result));
		return key.toString();
	}

	static function valueTypeKey(type:WasmValueType):String
		return switch type {
			case I32: "i";
			case I64: "l";
			case F32: "f";
			case F64: "d";
			case Ref(reference): (reference.nullable ? "?" : "!") + heapTypeKey(reference.heap) + ";";
		};

	static function heapTypeKey(heap:WasmTypes.WasmHeapType):String
		return switch heap {
			case Type(index): '$index';
			default: Std.string(heap);
		};
}
