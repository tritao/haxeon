package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmReflectionTable;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrProgram;

/**
 * Wasm GC's side of field reflection over object layouts: the table (see WasmReflectionTable) in an immutable i32 array
 * filled when the module starts, a lookup that binary-searches it by the class id at the start of every class struct, and
 * the four operations that call the per-layout function through the slot it finds. Memory-free, and independent of how
 * many classes the program has.
 */
class WasmGcReflection {
	static final ENTRY_FUNCTION = "__reflect_object_entry";

	/** Name of the global holding the table, in the module's global map. */
	public static inline final TABLE_GLOBAL = "__reflect_table";

	/**
	 * Adds the passive segment and the global for the table. Returns its bytes, which are filled once function-table slots
	 * are known, and the instructions that load them into the global before any Haxe code runs; null without reflection.
	 */
	public static function addTable(module:WasmModule, globals:Map<String, Int>, plan:WasmGcTypePlan,
			program:IrProgram):Null<{bytes:haxe.io.Bytes, init:Array<WasmInstruction>}> {
		var size = WasmReflectionTable.tableSize(program);
		if (size == 0)
			return null;
		if (plan.staticDataTypeIndex < 0)
			throw "Wasm GC reflection table has no planned array type";
		var bytes = haxe.io.Bytes.alloc(size);
		module.data.push({offset: 0, bytes: bytes, passive: true});
		var global = module.globals.length;
		module.globals.push({
			type: Ref({nullable: true, heap: Type(plan.staticDataTypeIndex)}),
			mutable: true,
			init: [RefNull(Type(plan.staticDataTypeIndex))]
		});
		globals.set(TABLE_GLOBAL, global);
		return {
			bytes: bytes,
			init: [
				I32Const(0),
				I32Const(size >> 2),
				ArrayNewData(plan.staticDataTypeIndex, module.data.length - 1),
				GlobalSet(global)
			]
		};
	}

	/** The function implementing `native` if it is one of the reflection operations, else null. */
	public static function define(module:WasmModule, functions:Map<String, Int>, globals:Map<String, Int>, plan:WasmGcTypePlan,
			representation:WasmGcRepresentation, program:IrProgram, native:IrNative):Null<Int> {
		var column = WasmReflectionTable.operationIndex(native.symbol);
		if (column < 0)
			return null;
		var table = globals.get(TABLE_GLOBAL);
		if (table == null)
			throw "Wasm GC reflection has no table global";
		var entry = functions.get(ENTRY_FUNCTION);
		if (entry == null) {
			entry = addEntryLookup(module, plan, table, Std.int(WasmReflectionTable.tableSize(program) / WasmReflectionTable.ROW_SIZE));
			functions.set(ENTRY_FUNCTION, entry);
		}
		var type = plan.wasmFunctionType(native.arguments, native.result), array = plan.staticDataTypeIndex, callType = module.typeIndex(type),
			row = native.arguments.length, slot = row + 1;
		var fallback = representation.zeroValue(native.result);
		var body:Array<WasmInstruction> = [LocalGet(0), Call(entry), LocalTee(row), I32Const(0), I32LtS, If(null)];
		body = body.concat(fallback).concat([Return, End]);
		body = body.concat([
			GlobalGet(table),
			LocalGet(row),
			I32Const(WasmReflectionTable.ROW_WORDS),
			I32Mul,
			I32Const(1 + column),
			I32Add,
			ArrayGet(array),
			LocalTee(slot),
			I32Const(0),
			I32LtS,
			If(null)
		]);
		body = body.concat(fallback).concat([Return, End]);
		for (index in 0...native.arguments.length)
			body.push(LocalGet(index));
		body.push(LocalGet(slot));
		body.push(CallIndirect(callType));
		body.push(Return);
		return module.addFunction(new WasmFunction(native.name, type, [{type: I32}, {type: I32}], body));
	}

	/** Index of the row for a value's class, or -1 for null and for a value that is not an instance of a class with a row. */
	static function addEntryLookup(module:WasmModule, plan:WasmGcTypePlan, table:Int, count:Int):Int {
		var root = plan.objectRootTypeIndex, array = plan.staticDataTypeIndex, id = 1, low = 2, high = 3, middle = 4, key = 5;
		var locals:Array<WasmLocal> = [for (_ in 0...5) {type: I32}];
		return module.addFunction(new WasmFunction(ENTRY_FUNCTION, plan.wasmFunctionType([Dyn], I32), locals, [
			LocalGet(0),
			RefTest({nullable: false, heap: Type(root)}),
			I32Eqz,
			If(null),
			I32Const(-1),
			Return,
			End,
			LocalGet(0),
			RefCast({nullable: false, heap: Type(root)}),
			StructGet(root, 0),
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
			GlobalGet(table),
			LocalGet(middle),
			I32Const(WasmReflectionTable.ROW_WORDS),
			I32Mul,
			ArrayGet(array),
			LocalSet(key),
			LocalGet(key),
			LocalGet(id),
			I32Eq,
			If(null),
			LocalGet(middle),
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
			I32Const(-1),
			Return
		]));
	}
}
