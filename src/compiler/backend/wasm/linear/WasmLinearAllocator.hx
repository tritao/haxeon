package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;

class WasmLinearAllocator {
	public static function build(context:WasmLinearContext):Int {
		var allocator = addAllocator(context);
		context.allocatorFunction = allocator;
		return allocator;
	}

	static function addAllocator(context:WasmLinearContext):Int {
		var module = context.module,
			collector = context.collectorFunction,
			heapStart = context.heapStart,
			heapTop = context.heapTop,
			freeHead = context.freeHead,
			gcBudget = context.gcBudget,
			gcStress = context.options.wasmGcStress == true,
			allocationCount = context.allocationCount,
			allocationBytes = context.allocationBytes,
			largestAllocation = context.largestAllocation;
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		var index = module.addFunction(new WasmFunction("__haxeon_alloc", type));
		// local 10 keeps requested payload bytes for diagnostics; local 0 becomes
		// the complete physical block size. Locals 5/11/12 track GC/reuse state.
		var findFreeBlock:Array<WasmInstruction> = [
			I32Const(0),
			LocalSet(1),
			I32Const(0),
			LocalSet(4),
			I32Const(0),
			LocalSet(11),
			GlobalGet(freeHead),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			I32Eqz,
			If(null),
			Br(2),
			Else,
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(7),
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET),
			LocalSet(9),
			LocalGet(0),
			LocalGet(7),
			I32LeS,
			If(null),
			LocalGet(3),
			LocalSet(1),
			LocalGet(7),
			LocalGet(0),
			I32Sub,
			LocalSet(8),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			// Consume a tail too small to hold another complete block header.
			LocalGet(7),
			LocalSet(6),
			LocalGet(4),
			I32Eqz,
			If(null),
			LocalGet(9),
			GlobalSet(freeHead),
			Else,
			LocalGet(4),
			LocalGet(9),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			Else,
			LocalGet(0),
			LocalSet(6),
			LocalGet(3),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			LocalGet(2),
			LocalGet(8),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(9),
			I32Store(0),
			LocalGet(4),
			I32Eqz,
			If(null),
			LocalGet(2),
			GlobalSet(freeHead),
			Else,
			LocalGet(4),
			LocalGet(2),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			End,
			I32Const(1),
			LocalSet(11),
			Br(3),
			Else,
			LocalGet(3),
			LocalSet(4),
			LocalGet(9),
			LocalSet(3),
			End,
			End,
			Br(0),
			End,
			End
		];
		var replenishBudget:Array<WasmInstruction> = [
			GlobalGet(heapTop),
			I32Const(heapStart),
			I32Sub,
			LocalSet(12),
			LocalGet(12),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			I32LtS,
			If(null),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			LocalSet(12),
			End,
			LocalGet(12),
			LocalGet(0),
			I32Sub,
			GlobalSet(gcBudget)
		];
		var body:Array<WasmInstruction> = [LocalGet(0), I32Const(7), I32Add, I32Const(-8), I32And, LocalSet(10)];
		if (allocationCount >= 0 && allocationBytes >= 0)
			body = body.concat([
				GlobalGet(allocationCount),
				I32Const(1),
				I32Add,
				GlobalSet(allocationCount),
				GlobalGet(allocationBytes),
				LocalGet(10),
				I32Add,
				GlobalSet(allocationBytes)
			]);
		if (largestAllocation >= 0)
			body = body.concat([
				GlobalGet(largestAllocation),
				LocalGet(10),
				I32LtS,
				If(null),
				LocalGet(10),
				GlobalSet(largestAllocation),
				End
			]);
		body = body.concat([
			LocalGet(10),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			LocalSet(0),
			I32Const(0),
			LocalSet(5)
		]);
		if (gcStress) {
			body = body.concat([Call(collector), I32Const(1), LocalSet(5)]);
		} else {
			body = body.concat([
				GlobalGet(gcBudget),
				LocalGet(0),
				I32LtS,
				If(null),
				Call(collector),
				I32Const(1),
				LocalSet(5)
			]);
			body = body.concat(replenishBudget);
			body = body.concat([Else, GlobalGet(gcBudget), LocalGet(0), I32Sub, GlobalSet(gcBudget), End]);
		}
		body = body.concat(findFreeBlock);
		body = body.concat([
			LocalGet(1),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(5),
			I32Eqz,
			If(null),
			// Collection on pressure is mandatory even before the budget expires.
			Call(collector),
			I32Const(1),
			LocalSet(5)
		]);
		if (!gcStress)
			body = body.concat(replenishBudget);
		body = body.concat(findFreeBlock);
		body = body.concat([End, End, End]);
		body = body.concat([
			LocalGet(1),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalSet(1),
			LocalGet(0),
			LocalSet(6),
			LocalGet(1),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(2),
			I32Const(65535),
			I32Add,
			I32Const(65536),
			I32DivS,
			MemorySize,
			I32Sub,
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			LocalGet(2),
			GlobalSet(heapTop),
			End,
			// Reused blocks must be cleared to preserve Haxe's zero defaults;
			// newly grown linear-memory pages are already zero-filled.
			LocalGet(11),
			If(null),
			LocalGet(1),
			I32Const(0),
			LocalGet(6),
			MemoryFill,
			End,
			LocalGet(1),
			LocalGet(6),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC | WasmLayout.GC_BLOCK_ALLOCATED | WasmLayout.GC_BLOCK_SCAN_REFERENCES),
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			Return
		]);
		module.setFunction(index, new WasmFunction("__haxeon_alloc", type, [for (_ in 0...12) {type: I32}], body));
		return index;
	}
}
