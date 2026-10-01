package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrProgram;

private typedef ReflectionRow = {final typeId:Int; final functions:Array<Null<String>>;}

/**
 * Field reflection over object layouts (`__reflect_object_*`): the program holds one function per layout, and this finds
 * the one for a value from the type id in its header. A static table of one row per class, sorted by type id, holds a
 * function-table slot per operation; a lookup binary-searches it and the operation calls through the slot. Code size
 * and lookup time do not grow with the number of classes the way a chain of type tests does.
 */
class WasmLinearReflection {
	static final OPERATIONS = [
		"__reflect_object_field",
		"__reflect_object_set_field",
		"__reflect_object_field_count",
		"__reflect_object_field_name"
	];

	/** Type id, then one slot for each of OPERATIONS. */
	public static inline final ROW_SIZE = 20;

	static final ENTRY_FUNCTION = "__reflect_object_entry";

	static function operationIndex(symbol:String):Int
		return OPERATIONS.indexOf(symbol);

	public static function declares(program:IrProgram):Bool {
		for (native in program.natives)
			if (operationIndex(native.symbol) >= 0)
				return true;
		return false;
	}

	/**
	 * A row for every class that has a layout of its own or inherits one, naming the per-layout functions of the nearest
	 * layout up its base chain, so an instance of a class that is not itself reflected still reflects as its base does.
	 */
	static function rows(program:IrProgram):Array<ReflectionRow> {
		var nativeNames:Array<Null<String>> = [for (_ in OPERATIONS) null],
			functionNames:Map<String, Bool> = [for (fn in program.functions) fn.name => true],
			objects = [for (object in program.objects) object.name => object];
		for (native in program.natives) {
			var index = operationIndex(native.symbol);
			if (index >= 0)
				nativeNames[index] = native.name;
		}
		var result:Array<ReflectionRow> = [];
		for (object in program.objects) {
			if (object.isValue)
				continue;
			var functions:Array<Null<String>> = [for (_ in OPERATIONS) null], owner:Null<String> = object.name, found = false;
			while (owner != null && !found) {
				for (index in 0...OPERATIONS.length) {
					var native = nativeNames[index];
					if (native != null && functionNames.exists('$native.$owner')) {
						functions[index] = '$native.$owner';
						found = true;
					}
				}
				if (!found) {
					var base = objects.get(owner);
					owner = base == null ? null : base.base;
				}
			}
			if (found)
				result.push({typeId: WasmModuleSupport.typeId(Obj(object.name)), functions: functions});
		}
		result.sort((left, right) -> left.typeId < right.typeId ? -1 : left.typeId > right.typeId ? 1 : 0);
		return result;
	}

	/** Bytes the table needs; the contents are filled in once function-table slots are known (finalize). */
	public static function tableSize(program:IrProgram):Int
		return declares(program) ? rows(program).length * ROW_SIZE : 0;

	/** The operation named by `native`, or null when it is not one of ours. */
	public static function define(context:WasmLinearContext, native:IrNative):Null<Int> {
		var column = operationIndex(native.symbol);
		if (column < 0)
			return null;
		var module = context.module, functions = context.functions;
		var entry = functions.get(ENTRY_FUNCTION);
		if (entry == null) {
			entry = addEntryLookup(module, context.reflectionTable, context.reflectionCount);
			functions.set(ENTRY_FUNCTION, entry);
		}
		var parameters:Array<compiler.backend.wasm.WasmTypes.WasmValueType> = [for (_ in native.arguments) I32];
		var callType = module.typeIndex({parameters: parameters, results: [I32]});
		var locals = parameters.length, body:Array<WasmInstruction> = [
			LocalGet(0),
			Call(entry),
			LocalTee(locals),
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(locals),
			I32Load(4 + 4 * column),
			LocalTee(locals + 1),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			Return,
			End
		];
		for (index in 0...parameters.length)
			body.push(LocalGet(index));
		body.push(LocalGet(locals + 1));
		body.push(CallIndirect(callType));
		body.push(Return);
		return module.addFunction(WasmFunctionBuilder.fromRaw(native.name, {parameters: parameters, results: [I32]}, [{type: I32}, {type: I32}], body));
	}

	/** Address of the matching row for a value, or 0 for null and for a value that is not an instance of a reflected class. */
	static function addEntryLookup(module:WasmModule, table:Int, count:Int):Int {
		var id = 1, low = 2, high = 3, middle = 4, row = 5, key = 6;
		return module.addFunction(WasmFunctionBuilder.fromRaw(ENTRY_FUNCTION, {parameters: [I32], results: [I32]}, [for (_ in 0...6) {type: I32}], [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			LocalSet(id),
			I32Const(0),
			LocalSet(low),
			I32Const(count),
			LocalSet(high),
			Block(null),
			Loop(null),
			LocalGet(low),
			LocalGet(high),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(low),
			LocalGet(high),
			I32Add,
			I32Const(1),
			I32ShrU,
			LocalSet(middle),
			LocalGet(middle),
			I32Const(ROW_SIZE),
			I32Mul,
			I32Const(table),
			I32Add,
			LocalSet(row),
			LocalGet(row),
			I32Load(0),
			LocalSet(key),
			LocalGet(key),
			LocalGet(id),
			I32Eq,
			If(null),
			LocalGet(row),
			Return,
			End,
			LocalGet(key),
			LocalGet(id),
			I32LtS,
			If(null),
			LocalGet(middle),
			I32Const(1),
			I32Add,
			LocalSet(low),
			Else,
			LocalGet(middle),
			LocalSet(high),
			End,
			Br(0),
			End,
			End,
			I32Const(0),
			Return
		]));
	}

	/** Writes the rows once every function has a slot in the table; a function the program never reaches gets -1. */
	public static function finalize(context:WasmLinearContext, slots:Map<String, Int>):Void {
		var bytes = context.reflectionBytes;
		if (bytes == null)
			return;
		var all = rows(context.program);
		for (index in 0...all.length) {
			var offset = index * ROW_SIZE;
			bytes.setInt32(offset, all[index].typeId);
			for (column in 0...OPERATIONS.length) {
				var name = all[index].functions[column],
					slot = name == null ? null : slots.get(name);
				bytes.setInt32(offset + 4 + 4 * column, slot == null ? -1 : slot);
			}
		}
	}
}
