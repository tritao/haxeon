package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
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
		var builder = new WasmFunctionBuilder("__haxeon_alloc", type),
			index = builder.register(module),
			requestedSize = builder.parameter("requestedSize", 0),
			selectedBlock = builder.local("selectedBlock", I32),
			heapEnd = builder.local("heapEnd", I32),
			freeCursor = builder.local("freeCursor", I32),
			previousFreeBlock = builder.local("previousFreeBlock", I32),
			collectionAttempted = builder.local("collectionAttempted", I32),
			blockSize = builder.local("blockSize", I32),
			freeBlockSize = builder.local("freeBlockSize", I32),
			remainderSize = builder.local("remainderSize", I32),
			nextFreeBlock = builder.local("nextFreeBlock", I32),
			alignedPayloadSize = builder.local("alignedPayloadSize", I32),
			reusedBlock = builder.local("reusedBlock", I32),
			heapUsed = builder.local("heapUsed", I32);
		// The parameter is promoted to a physical block size after alignedPayloadSize
		// captures the requested payload bytes for diagnostics.
		var findFreeBlock:Array<WasmInstruction> = [
			I32Const(0),
			LocalSet(selectedBlock),
			I32Const(0),
			LocalSet(previousFreeBlock),
			I32Const(0),
			LocalSet(reusedBlock),
			GlobalGet(freeHead),
			LocalSet(freeCursor),
			Block(null),
			Loop(null),
			LocalGet(freeCursor),
			I32Eqz,
			If(null),
			Br(2),
			Else,
			LocalGet(freeCursor),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(freeBlockSize),
			LocalGet(freeCursor),
			I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET),
			LocalSet(nextFreeBlock),
			LocalGet(requestedSize),
			LocalGet(freeBlockSize),
			I32LeS,
			If(null),
			LocalGet(freeCursor),
			LocalSet(selectedBlock),
			LocalGet(freeBlockSize),
			LocalGet(requestedSize),
			I32Sub,
			LocalSet(remainderSize),
			LocalGet(remainderSize),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			// Consume a tail too small to hold another complete block header.
			LocalGet(freeBlockSize),
			LocalSet(blockSize),
			LocalGet(previousFreeBlock),
			I32Eqz,
			If(null),
			LocalGet(nextFreeBlock),
			GlobalSet(freeHead),
			Else,
			LocalGet(previousFreeBlock),
			LocalGet(nextFreeBlock),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			Else,
			LocalGet(requestedSize),
			LocalSet(blockSize),
			LocalGet(freeCursor),
			LocalGet(requestedSize),
			I32Add,
			LocalSet(heapEnd),
			LocalGet(heapEnd),
			LocalGet(remainderSize),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(heapEnd),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Store(0),
			LocalGet(heapEnd),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(heapEnd),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(nextFreeBlock),
			I32Store(0),
			LocalGet(previousFreeBlock),
			I32Eqz,
			If(null),
			LocalGet(heapEnd),
			GlobalSet(freeHead),
			Else,
			LocalGet(previousFreeBlock),
			LocalGet(heapEnd),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			End,
			I32Const(1),
			LocalSet(reusedBlock),
			Br(3),
			Else,
			LocalGet(freeCursor),
			LocalSet(previousFreeBlock),
			LocalGet(nextFreeBlock),
			LocalSet(freeCursor),
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
			LocalSet(heapUsed),
			LocalGet(heapUsed),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			I32LtS,
			If(null),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			LocalSet(heapUsed),
			End,
			LocalGet(heapUsed),
			LocalGet(requestedSize),
			I32Sub,
			GlobalSet(gcBudget)
		];
		var body:Array<WasmInstruction> = [
			LocalGet(requestedSize),
			I32Const(7),
			I32Add,
			I32Const(-8),
			I32And,
			LocalSet(alignedPayloadSize)
		];
		if (allocationCount >= 0 && allocationBytes >= 0)
			body = body.concat([
				GlobalGet(allocationCount),
				I32Const(1),
				I32Add,
				GlobalSet(allocationCount),
				GlobalGet(allocationBytes),
				LocalGet(alignedPayloadSize),
				I32Add,
				GlobalSet(allocationBytes)
			]);
		if (largestAllocation >= 0)
			body = body.concat([
				GlobalGet(largestAllocation),
				LocalGet(alignedPayloadSize),
				I32LtS,
				If(null),
				LocalGet(alignedPayloadSize),
				GlobalSet(largestAllocation),
				End
			]);
		body = body.concat([
			LocalGet(alignedPayloadSize),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			LocalSet(requestedSize),
			I32Const(0),
			LocalSet(collectionAttempted)
		]);
		if (gcStress) {
			body = body.concat([Call(collector), I32Const(1), LocalSet(collectionAttempted)]);
		} else {
			body = body.concat([
				GlobalGet(gcBudget),
				LocalGet(requestedSize),
				I32LtS,
				If(null),
				Call(collector),
				I32Const(1),
				LocalSet(collectionAttempted)
			]);
			body = body.concat(replenishBudget);
			body = body.concat([
				Else,
				GlobalGet(gcBudget),
				LocalGet(requestedSize),
				I32Sub,
				GlobalSet(gcBudget),
				End
			]);
		}
		body = body.concat(findFreeBlock);
		body = body.concat([
			LocalGet(selectedBlock),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalGet(requestedSize),
			I32Add,
			LocalSet(heapEnd),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(heapEnd),
			I32LtS,
			If(null),
			LocalGet(collectionAttempted),
			I32Eqz,
			If(null),
			// Collection on pressure is mandatory even before the budget expires.
			Call(collector),
			I32Const(1),
			LocalSet(collectionAttempted)
		]);
		if (!gcStress)
			body = body.concat(replenishBudget);
		body = body.concat(findFreeBlock);
		body = body.concat([End, End, End]);
		body = body.concat([
			LocalGet(selectedBlock),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalSet(selectedBlock),
			LocalGet(requestedSize),
			LocalSet(blockSize),
			LocalGet(selectedBlock),
			LocalGet(requestedSize),
			I32Add,
			LocalSet(heapEnd),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(heapEnd),
			I32LtS,
			If(null),
			LocalGet(heapEnd),
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
			LocalGet(heapEnd),
			GlobalSet(heapTop),
			End,
			// Reused blocks must be cleared to preserve Haxe's zero defaults;
			// newly grown linear-memory pages are already zero-filled.
			LocalGet(reusedBlock),
			If(null),
			LocalGet(selectedBlock),
			I32Const(0),
			LocalGet(blockSize),
			MemoryFill,
			End,
			LocalGet(selectedBlock),
			LocalGet(blockSize),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(selectedBlock),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC | WasmLayout.GC_BLOCK_ALLOCATED | WasmLayout.GC_BLOCK_SCAN_REFERENCES),
			I32Store(0),
			LocalGet(selectedBlock),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			LocalGet(selectedBlock),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			I32Store(0),
			LocalGet(selectedBlock),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(selectedBlock),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			Return
		]);
		builder.emitAll(body);
		module.setFunction(index, builder.finish());
		return index;
	}
}
