package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmReflectionTable;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.ir.Ir.IrNative;

/**
 * Linear Wasm's side of field reflection over object layouts: a lookup that binary-searches the table in memory by the type
 * id at the start of every object, and the four operations that call the per-layout function through the slot it finds
 * (see WasmReflectionTable).
 */
class WasmLinearReflection {
	static final ENTRY_FUNCTION = "__reflect_object_entry";

	/** The operation named by `native`, or null when it is not one of ours. */
	public static function define(context:WasmLinearContext, native:IrNative):Null<Int> {
		var column = WasmReflectionTable.operationIndex(native.symbol);
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
			I32Const(WasmReflectionTable.ROW_SIZE),
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

	/** Writes the rows once every function has a slot in the table. */
	public static function finalize(context:WasmLinearContext, slots:Map<String, Int>):Void {
		if (context.reflectionBytes != null)
			WasmReflectionTable.fill(context.reflectionBytes, context.program, slots);
	}
}
