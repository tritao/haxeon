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
		var type:WasmFunctionType = {parameters: [I32], results: [I32]},
			builder = new WasmFunctionBuilder("__haxeon_alloc", type),
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

		function replenishBudget(builder:WasmFunctionBuilder):Void {
			builder.globalGet(builder.global(heapTop));
			builder.i32Const(heapStart);
			builder.i32Sub();
			builder.localSet(heapUsed);
			builder.localGet(heapUsed);
			builder.i32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.i32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET);
				builder.localSet(heapUsed);
			});
			builder.localGet(heapUsed);
			builder.localGet(requestedSize);
			builder.i32Sub();
			builder.globalSet(builder.global(gcBudget));
		}

		function findFreeBlock(builder:WasmFunctionBuilder):Void {
			builder.i32Const(0);
			builder.localSet(selectedBlock);
			builder.i32Const(0);
			builder.localSet(previousFreeBlock);
			builder.i32Const(0);
			builder.localSet(reusedBlock);
			builder.globalGet(builder.global(freeHead));
			builder.localSet(freeCursor);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(freeCursor);
					builder.i32Eqz();
					builder.ifElse(function(builder) {
						builder.emit(Br(2));
					}, function(builder) {
						builder.localGet(freeCursor);
						builder.emit(I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET));
						builder.localSet(freeBlockSize);
						builder.localGet(freeCursor);
						builder.emit(I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET));
						builder.localSet(nextFreeBlock);
						builder.localGet(requestedSize);
						builder.localGet(freeBlockSize);
						builder.emit(I32LeS);
						builder.ifElse(function(builder) {
							builder.localGet(freeCursor);
							builder.localSet(selectedBlock);
							builder.localGet(freeBlockSize);
							builder.localGet(requestedSize);
							builder.i32Sub();
							builder.localSet(remainderSize);
							builder.localGet(remainderSize);
							builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
							builder.emit(I32LtS);
							builder.ifElse(function(builder) {
								builder.localGet(freeBlockSize);
								builder.localSet(blockSize);
								builder.localGet(previousFreeBlock);
								builder.i32Eqz();
								builder.ifElse(function(builder) {
									builder.localGet(nextFreeBlock);
									builder.globalSet(builder.global(freeHead));
								}, function(builder) {
									builder.localGet(previousFreeBlock);
									builder.localGet(nextFreeBlock);
									builder.emit(I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET));
								});
							}, function(builder) {
								builder.localGet(requestedSize);
								builder.localSet(blockSize);
								builder.localGet(freeCursor);
								builder.localGet(requestedSize);
								builder.i32Add();
								builder.localSet(heapEnd);
								builder.localGet(heapEnd);
								builder.localGet(remainderSize);
								builder.emit(I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET));
								builder.localGet(heapEnd);
								builder.i32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET);
								builder.i32Add();
								builder.i32Const(WasmLayout.GC_BLOCK_MAGIC);
								builder.emit(I32Store(0));
								builder.localGet(heapEnd);
								builder.i32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET);
								builder.i32Add();
								builder.i32Const(0);
								builder.emit(I32Store(0));
								builder.localGet(heapEnd);
								builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
								builder.i32Add();
								builder.localGet(nextFreeBlock);
								builder.emit(I32Store(0));
								builder.localGet(previousFreeBlock);
								builder.i32Eqz();
								builder.ifElse(function(builder) {
									builder.localGet(heapEnd);
									builder.globalSet(builder.global(freeHead));
								}, function(builder) {
									builder.localGet(previousFreeBlock);
									builder.localGet(heapEnd);
									builder.emit(I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET));
								});
							});
							builder.i32Const(1);
							builder.localSet(reusedBlock);
							builder.emit(Br(3));
						}, function(builder) {
							builder.localGet(freeCursor);
							builder.localSet(previousFreeBlock);
							builder.localGet(nextFreeBlock);
							builder.localSet(freeCursor);
						});
					});
					builder.emit(Br(0));
				});
			});
		}

		builder.localGet(requestedSize);
		builder.i32Const(7);
		builder.i32Add();
		builder.i32Const(-8);
		builder.emit(I32And);
		builder.localSet(alignedPayloadSize);
		if (allocationCount >= 0 && allocationBytes >= 0) {
			builder.globalGet(builder.global(allocationCount));
			builder.i32Const(1);
			builder.i32Add();
			builder.globalSet(builder.global(allocationCount));
			builder.globalGet(builder.global(allocationBytes));
			builder.localGet(alignedPayloadSize);
			builder.i32Add();
			builder.globalSet(builder.global(allocationBytes));
		}
		if (largestAllocation >= 0) {
			builder.globalGet(builder.global(largestAllocation));
			builder.localGet(alignedPayloadSize);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.localGet(alignedPayloadSize);
				builder.globalSet(builder.global(largestAllocation));
			});
		}
		builder.localGet(alignedPayloadSize);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Add();
		builder.localSet(requestedSize);
		builder.i32Const(0);
		builder.localSet(collectionAttempted);
		if (gcStress) {
			builder.call(builder.functionRef(collector));
			builder.i32Const(1);
			builder.localSet(collectionAttempted);
		} else {
			builder.globalGet(builder.global(gcBudget));
			builder.localGet(requestedSize);
			builder.emit(I32LtS);
			builder.ifElse(function(builder) {
				builder.call(builder.functionRef(collector));
				builder.i32Const(1);
				builder.localSet(collectionAttempted);
				replenishBudget(builder);
			}, function(builder) {
				builder.globalGet(builder.global(gcBudget));
				builder.localGet(requestedSize);
				builder.i32Sub();
				builder.globalSet(builder.global(gcBudget));
			});
		}
		findFreeBlock(builder);
		builder.localGet(selectedBlock);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.globalGet(builder.global(heapTop));
			builder.localGet(requestedSize);
			builder.i32Add();
			builder.localSet(heapEnd);
			builder.emit(MemorySize);
			builder.i32Const(65536);
			builder.emit(I32Mul);
			builder.localGet(heapEnd);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.localGet(collectionAttempted);
				builder.i32Eqz();
				builder.if_(function(builder) {
					// Collection on pressure is mandatory even before the budget expires.
					builder.call(builder.functionRef(collector));
					builder.i32Const(1);
					builder.localSet(collectionAttempted);
					if (!gcStress)
						replenishBudget(builder);
					findFreeBlock(builder);
				});
			});
		});
		builder.localGet(selectedBlock);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.globalGet(builder.global(heapTop));
			builder.localSet(selectedBlock);
			builder.localGet(requestedSize);
			builder.localSet(blockSize);
			builder.localGet(selectedBlock);
			builder.localGet(requestedSize);
			builder.i32Add();
			builder.localSet(heapEnd);
			builder.emit(MemorySize);
			builder.i32Const(65536);
			builder.emit(I32Mul);
			builder.localGet(heapEnd);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.localGet(heapEnd);
				builder.i32Const(65535);
				builder.i32Add();
				builder.i32Const(65536);
				builder.emit(I32DivS);
				builder.emit(MemorySize);
				builder.emit(I32Sub);
				builder.emit(MemoryGrow);
				builder.i32Const(-1);
				builder.emit(I32Eq);
				builder.if_(function(builder) builder.emit(Unreachable));
			});
			builder.localGet(heapEnd);
			builder.globalSet(builder.global(heapTop));
		});
		// Reused blocks must be cleared to preserve Haxe's zero defaults;
		// newly grown linear-memory pages are already zero-filled.
		builder.localGet(reusedBlock);
		builder.if_(function(builder) {
			builder.localGet(selectedBlock);
			builder.i32Const(0);
			builder.localGet(blockSize);
			builder.emit(MemoryFill);
		});
		builder.localGet(selectedBlock);
		builder.localGet(blockSize);
		builder.emit(I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET));
		builder.localGet(selectedBlock);
		builder.i32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET);
		builder.i32Add();
		builder.i32Const(WasmLayout.GC_BLOCK_MAGIC | WasmLayout.GC_BLOCK_ALLOCATED | WasmLayout.GC_BLOCK_SCAN_REFERENCES);
		builder.emit(I32Store(0));
		builder.localGet(selectedBlock);
		builder.i32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET);
		builder.i32Add();
		builder.localGet(selectedBlock);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Add();
		builder.emit(I32Store(0));
		builder.localGet(selectedBlock);
		builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
		builder.i32Add();
		builder.i32Const(0);
		builder.emit(I32Store(0));
		builder.localGet(selectedBlock);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Add();
		builder.return_();
		module.setFunction(index, builder.finish());
		return index;
	}
}
