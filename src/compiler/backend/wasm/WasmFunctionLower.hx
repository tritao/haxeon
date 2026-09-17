package compiler.backend.wasm;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import haxe.io.Bytes as HaxeBytes;
import compiler.backend.wasm.WasmModuleSupport.WasmClosureTypes;
import compiler.backend.wasm.WasmCfgAnalysis;
import compiler.backend.wasm.gc.WasmGcMaps;
import compiler.backend.wasm.gc.WasmGcRoots.WasmSafepoint;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmStructurer.WasmLoopInfo;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmFunctionLowerContext.WasmFunctionGcRootState;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.gc.WasmGcRepresentation;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

class WasmFunctionLower {
	final context:WasmFunctionLowerContext;

	function new(context:WasmFunctionLowerContext) {
		this.context = context;
	}

	static function requiredLocal(locals:Map<Int, Int>, valueId:Int):Int {
		if (!locals.exists(valueId))
			throw 'Unknown Wasm local for value $valueId';
		return locals.get(valueId);
	}

	static function elidedDynamicArrayCasts(fn:IrFunction, representation:WasmRepresentationSet):Map<Int, IrValue> {
		// A GC Array<Dynamic> wrapper cannot cast an element-typed array wrapper. When
		// flow narrowing is immediately erased again, preserve the original anyref.
		var result:Map<Int, IrValue> = [];
		if (!Std.isOfType(representation.values, WasmGcRepresentation))
			return result;
		var candidates:Map<Int, IrValue> = [],
			invalid:Map<Int, Bool> = [],
			uses:Map<Int, Int> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case SafeCast(output, value) if (value.type == Dyn && isDynamicArrayType(output.type)):
						candidates.set(output.id, value);
					default:
				}
		for (block in fn.blocks)
			for (located in block.instructions)
				for (input in IrOperands.inputs(located.value))
					if (candidates.exists(input.id))
						switch located.value {
							case ToDyn(_, value) if (value.id == input.id):
								var previous = uses.get(input.id);
								uses.set(input.id, (previous == null ? 0 : previous) + 1);
							default:
								invalid.set(input.id, true);
						}
		for (valueId in candidates.keys())
			if (!invalid.exists(valueId) && uses.get(valueId) == 1)
				result.set(valueId, candidates.get(valueId));
		return result;
	}

	static function isDynamicArrayType(type:IrType):Bool
		return switch type {
			case Array(Dyn): true;
			default: false;
		};

	static function requiredBlockIndex(blocks:Map<Int, Int>, blockId:Int):Int {
		if (!blocks.exists(blockId))
			throw 'Unknown Wasm block $blockId';
		return blocks.get(blockId);
	}

	public static function lower(module:WasmModule, fn:IrFunction, functions:Map<String, Int>, type:WasmFunctionType, layout:WasmLayout, allocator:Int,
			rootTop:Int, rootFrameTop:Int, rootLimit:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>, tableSlots:Map<String, Int>, exceptionTag:Null<Int>, rootPoints:Array<WasmSafepoint>,
			program:IrProgram, representation:WasmRepresentationSet, staticDataAddresses:Map<String, Int>):WasmFunction {
		var context = new WasmFunctionLowerContext(module, fn, program, representation, tableSlots, staticDataAddresses, exceptionTag, rootPoints);
		return new WasmFunctionLower(context).lowerFunction(functions, type, layout, allocator, rootTop, rootFrameTop, rootLimit, globals, strings, methods,
			closureTypes);
	}

	function lowerFunction(functions:Map<String, Int>, type:WasmFunctionType, layout:WasmLayout, allocator:Int, rootTop:Int, rootFrameTop:Int, rootLimit:Int,
			globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):WasmFunction {
		var fn = context.irFunction,
			analysis = new WasmCfgAnalysis(fn),
			placement = context.placement,
			valueLocals = context.valueLocals,
			locals = context.locals;
		context.elidedDynamicArrayCasts = elidedDynamicArrayCasts(fn, context.representation);
		var rootLocals:Array<Int> = [],
			rootIds:Map<Int, Bool> = [],
			live:Map<Int, Map<Int, Array<Int>>> = [];
		for (point in context.rootPoints) {
			var blockLive = live.get(point.block);
			if (blockLive == null) {
				blockLive = [];
				live.set(point.block, blockLive);
			}
			blockLive.set(point.instruction, point.liveReferences);
			for (valueId in point.liveReferences) {
				rootIds.set(valueId, true);
			}
		}
		var rootValueIds = [for (valueId in rootIds.keys()) valueId];
		rootValueIds.sort(function(left, right) return left - right);
		var slotByValue:Map<Int, Int> = [];
		for (index in 0...rootValueIds.length) {
			slotByValue.set(rootValueIds[index], index);
			rootLocals.push(requiredLocal(valueLocals, rootValueIds[index]));
		}
		var rootFrame = rootLocals.length == 0 ? null : placement.allocate(I32);
		context.gcRootState = rootFrame == null ? null : {
			frame: rootFrame,
			top: rootTop,
			frameTop: rootFrameTop,
			slots: rootLocals,
			slotByValue: slotByValue,
			live: live,
			size: align(12 + rootLocals.length * 4, 8)
		};
		context.exceptionState = null;
		if (context.exceptionTag != null) {
			var blocks:Map<Int, Int> = [], orderIndex = 0;
			for (id in analysis.graph.order)
				blocks.set(id, orderIndex++);
			var saved:Map<Int, Int> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case BeginTry(catchBlock, _):
							if (!saved.exists(catchBlock))
								saved.set(catchBlock, placement.allocate(I32));
						default:
					}
			context.exceptionState = {
				handler: placement.allocate(I32),
				exception: placement.allocate(context.representation.values.valueType(Dyn)),
				saved: saved,
				blocks: blocks,
				tag: cast context.exceptionTag
			};
		}
		var predecessor = placement.allocate(I32);
		var structurer = new WasmStructurer(fn),
			body:Array<WasmInstruction> = null;
		if (context.exceptionState == null && structurer.canUseStructured())
			try
				body = lowerStructured(fn, structurer, functions, valueLocals, predecessor, layout, allocator, globals, strings, methods, closureTypes)
			catch (_:Dynamic) {}
		if (body == null) {
			var pc = placement.allocate(I32);
			body = lowerDispatcher(fn, analysis, functions, valueLocals, pc, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		}
		var rootState = context.gcRootState;
		if (rootState != null) {
			var rooted:Array<WasmInstruction> = rootPrologue(rootState, rootLimit);
			rooted = rooted.concat(body);
			if (context.exceptionTag != null) {
				var exceptionLocal = placement.allocate(context.representation.values.valueType(Dyn)),
					protectedBody:Array<WasmInstruction> = [Try(null)];
				protectedBody = protectedBody.concat(rooted);
				protectedBody = protectedBody.concat([Catch(cast context.exceptionTag), LocalSet(exceptionLocal)]);
				restoreRoots(protectedBody);
				protectedBody = protectedBody.concat([LocalGet(exceptionLocal), Throw(cast context.exceptionTag), End, Unreachable]);
				rooted = protectedBody;
			}
			body = rooted;
		}
		body = WasmOptimizer.optimize(body);
		return new WasmFunction(fn.name, type, locals, body);
	}

	function lowerStructured(fn:IrFunction, structurer:WasmStructurer, functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, layout:WasmLayout,
			allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [];
		emit(body, [I32Const(-1), LocalSet(predecessor)]);
		if (!emitPath(body, fn.blocks[0].id, null, null, 0, structurer, functions, values, predecessor, [], layout, allocator, globals, strings, methods,
			closureTypes))
			throw 'Unable to structure CFG for ${fn.name}';
		body.push(Unreachable);
		return body;
	}

	function emitPath(body:Array<WasmInstruction>, start:Int, stop:Null<Int>, activeLoop:Null<Int>, loopDepth:Int, structurer:WasmStructurer,
			functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>,
			strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		var current = start;
		while (stop == null || current != stop) {
			if (visited.indexOf(current) >= 0)
				return false;
			visited.push(current);
			var block = structurer.analysis.graph.block(current);
			var loop = structurer.loops.get(block.id);
			if (loop != null) {
				if (!emitLoop(body, block, loop, structurer, functions, values, predecessor, visited, layout, allocator, globals, strings, methods,
					closureTypes))
					return false;
				if (stop != null && loop.exit == stop)
					return true;
				current = loop.exit;
				continue;
			}
			emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
			if (block.terminator == null)
				return false;
			switch block.terminator.value {
				case Return(value):
					restoreRoots(body);
					if (value.type != Void)
						body.push(LocalGet(requiredLocal(values, value.id)));
					body.push(Return);
					return true;
				case Throw(_), Rethrow(_):
					body.push(Unreachable);
					return true;
				case Jump(target):
					if (activeLoop != null && target == activeLoop) {
						setPredecessor(body, predecessor, block.id);
						body.push(Br(loopDepth));
						return true;
					}
					setPredecessor(body, predecessor, block.id);
					if (stop != null && target == stop)
						return true;
					current = target;
				case Branch(condition, yes, no):
					var merge = structurer.analysis.mergeFor(yes, no);
					if (merge == null)
						return false;
					emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, yes, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(Else);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, no, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(End);
					if (stop != null && merge == stop)
						return true;
					current = merge;
			}
		}
		return true;
	}

	function emitLoop(body:Array<WasmInstruction>, block:IrBlock, loop:WasmLoopInfo, structurer:WasmStructurer, functions:Map<String, Int>,
			values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>,
			methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		if (block.terminator == null)
			return false;
		var condition:Null<IrValue> = null, whenTrue = -1, whenFalse = -1;
		switch block.terminator.value {
			case Branch(value, yes, no):
				condition = value;
				whenTrue = yes;
				whenFalse = no;
			default:
		}
		if (condition == null || (loop.body != whenTrue && loop.body != whenFalse))
			return false;
		emit(body, [Block(null), Loop(null)]);
		emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
		if (loop.body == whenTrue) {
			setPredecessor(body, predecessor, block.id);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
			body.push(Else);
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2)]);
		} else {
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2), Else]);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
		}
		emit(body, [End, End, End]);
		return true;
	}

	function emitBlockInstructions(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			// Safepoint liveness describes the instruction's entry state; snapshot before it can allocate or collect.
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
		}
	}

	function lowerDispatcher(fn:IrFunction, analysis:WasmCfgAnalysis, functions:Map<String, Int>, values:Map<Int, Int>, pc:Int, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [], blockIndex:Map<Int, Int> = [];
		var next = 0;
		for (id in analysis.graph.order)
			blockIndex.set(id, next++);
		var exceptionState = context.exceptionState;
		emit(body, [
			I32Const(requiredBlockIndex(blockIndex, fn.blocks[0].id)),
			LocalSet(pc),
			I32Const(-1),
			LocalSet(predecessor)
		]);
		if (exceptionState != null) {
			emit(body, [I32Const(-1), LocalSet(exceptionState.handler)]);
		}
		emit(body, [Block(null), Loop(null)]);
		if (exceptionState != null)
			body.push(Try(null));
		for (index in 0...analysis.graph.order.length) {
			var block = analysis.graph.block(analysis.graph.order[index]);
			emit(body, [LocalGet(pc), I32Const(index), I32Eq, If(null)]);
			lowerBlock(body, block, values, functions, pc, predecessor, blockIndex, layout, allocator, globals, strings, methods, closureTypes);
			if (index < analysis.graph.order.length - 1)
				body.push(Else);
			else
				emit(body, [Else, Unreachable]);
		}
		for (_ in 0...analysis.graph.order.length)
			body.push(End);
		if (exceptionState == null) {
			emit(body, [Br(0), End, End, Unreachable]);
		} else {
			emit(body, [Br(1), Catch(exceptionState.tag), LocalSet(exceptionState.exception)]);
			emit(body, [LocalGet(exceptionState.handler), I32Const(-1), I32Eq, If(null)]);
			emit(body, [LocalGet(exceptionState.exception), Throw(exceptionState.tag), Else]);
			var catches = [for (catchBlock in exceptionState.saved.keys()) catchBlock];
			catches.sort(function(left, right) return left - right);
			for (catchBlock in catches) {
				emit(body, [
					LocalGet(exceptionState.handler),
					I32Const(requiredBlockIndex(blockIndex, catchBlock)),
					I32Eq,
					If(null)
				]);
				emit(body, [LocalGet(exceptionState.handler), LocalSet(pc)]);
				emit(body, [
					LocalGet(requiredLocal(exceptionState.saved, catchBlock)),
					LocalSet(exceptionState.handler)
				]);
				body.push(Else);
			}
			body.push(Unreachable);
			for (_ in catches)
				body.push(End);
			emit(body, [End, Br(1), End, End, End, Unreachable]);
		}
		return body;
	}

	public static function hasExceptions(fn:IrFunction):Bool {
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						return true;
					default:
				}
			if (block.terminator != null)
				switch block.terminator.value {
					case Throw(_), Rethrow(_):
						return true;
					default:
				}
		}
		return false;
	}

	function lowerBlock(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, pc:Int, predecessor:Int,
			blockIndex:Map<Int, Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		var exceptionState = context.exceptionState;
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
		}
		if (block.terminator == null)
			throw 'Missing terminator in Wasm block ${block.id}';
		switch block.terminator.value {
			case Return(value):
				restoreRoots(body);
				if (value.type != Void)
					body.push(LocalGet(requiredLocal(values, value.id)));
				body.push(Return);
			case Throw(value), Rethrow(value):
				if (exceptionState == null)
					body.push(Unreachable);
				else
					emit(body, [LocalGet(requiredLocal(values, value.id)), Throw(exceptionState.tag)]);
			case Jump(target):
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, target));
			case Branch(condition, yes, no):
				emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, yes));
				body.push(Else);
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, no));
				body.push(End);
		}
	}

	static function setPcAndContinue(body:Array<WasmInstruction>, pc:Int, predecessor:Int, sourceBlock:Int, target:Int):Void {
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor), I32Const(target), LocalSet(pc)]);
	}

	function trapOrThrow():Array<WasmInstruction> {
		var exceptionState = context.exceptionState;
		return exceptionState == null ? [Unreachable] : context.representation.values.zeroValue(Dyn).concat([Throw(exceptionState.tag)]);
	}

	static function setPredecessor(body:Array<WasmInstruction>, predecessor:Int, sourceBlock:Int):Void
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor)]);

	function lowerInstruction(body:Array<WasmInstruction>, instruction:IrInstruction, values:Map<Int, Int>, functions:Map<String, Int>, layout:WasmLayout,
			allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Void {
		var exceptionState = context.exceptionState;
		switch instruction {
			case Phi(_, _):
			case PointerOffset(_, _, _), MemoryLoad(_, _, _, _), MemoryStore(_, _, _):
				throw "Wasm lowering does not support unmanaged RawPtr memory instructions yet";
			case ConstInt(output, value):
				emit(body, [
					output.type == I64 ? I64Const(value) : I32Const(value),
					LocalSet(requiredLocal(values, output.id))
				]);
			case ConstBool(output, value):
				emit(body, [I32Const(value ? 1 : 0), LocalSet(requiredLocal(values, output.id))]);
			case ConstFloat(output, value):
				emit(body, [F64Const(value), LocalSet(requiredLocal(values, output.id))]);
			case ConstNull(output):
				emit(body, context.representation.values.nullValue(output.type, requiredLocal(values, output.id)));
			case ConstVoid(_):
			case TypeValue(output, type):
				emit(body, [I32Const(typeId(type)), LocalSet(requiredLocal(values, output.id))]);
			case ToDyn(output, value):
				var original = context.elidedDynamicArrayCasts.get(value.id),
					dynamicValue = original == null ? value : original,
					represented = context.representation.values.toDynamic(dynamicValue, requiredLocal(values, output.id),
						requiredLocal(values, dynamicValue.id));
				if (emitIfHandled(body, represented)) {} else
					switch value.type {
						case I32, Bool:
							emit(body, [
								I32Const(WasmLayout.DYN_I32_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(value.type)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								I32Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						case F64:
							emit(body, [
								I32Const(WasmLayout.DYN_F64_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(F64)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								F64Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						case I64:
							emit(body, [
								I32Const(WasmLayout.DYN_I64_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(I64)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								I64Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						default:
							emit(body, [
								LocalGet(requiredLocal(values, value.id)),
								LocalSet(requiredLocal(values, output.id))
							]);
					}
			case SafeCast(output, value):
				if (!context.elidedDynamicArrayCasts.exists(output.id)) {
					var represented = context.representation.values.safeCast(output, value, requiredLocal(values, output.id), requiredLocal(values, value.id));
					if (emitIfHandled(body, represented)) {} else
						switch output.type {
							case I32, Bool, I64, F64 if (value.type == Dyn):
								emit(body, [
									LocalGet(requiredLocal(values, value.id)),
									I32Load(0),
									I32Const(typeId(output.type)),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, value.id)),
									load(output.type, WasmLayout.DYN_PAYLOAD_OFFSET),
									LocalSet(requiredLocal(values, output.id)),
									Else,
									Unreachable,
									End
								]);
							default:
								emit(body, [
									LocalGet(requiredLocal(values, value.id)),
									LocalSet(requiredLocal(values, output.id))
								]);
						}
				}
			case BeginTry(catchBlock, _):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = requiredLocal(exceptionState.saved, catchBlock),
					target = requiredBlockIndex(exceptionState.blocks, catchBlock);
				emit(body, [
					LocalGet(exceptionState.handler),
					LocalSet(saved),
					I32Const(target),
					LocalSet(exceptionState.handler)
				]);
			case EndTry(catchBlock):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = requiredLocal(exceptionState.saved, catchBlock);
				emit(body, [LocalGet(saved), LocalSet(exceptionState.handler)]);
			case Catch(output):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				emit(body, [LocalGet(exceptionState.exception), LocalSet(requiredLocal(values, output.id))]);
			case GlobalGet(output, name):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [GlobalGet(global), LocalSet(requiredLocal(values, output.id))]);
			case GlobalSet(name, value):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [LocalGet(requiredLocal(values, value.id)), GlobalSet(global)]);
			case StaticClosure(output, name):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm closure target "$name" is not emitted';
				var tableSlot = context.tableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm closure target "$name" has no stable table slot';
				var calls = context.representation.calls,
					represented = calls == null ? UseDefault : calls.staticClosure(name, context.tableSlots, requiredLocal(values, output.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [I32Const(tableSlot * 2 + 1), LocalSet(requiredLocal(values, output.id))]);
			case CallClosure(output, closure, arguments):
				var typeInfo = closureTypes.get(Std.string(closure.type));
				if (typeInfo == null)
					throw 'Wasm closure type ${Std.string(closure.type)} has no indirect signature';
				var calls = context.representation.calls,
					instanceType = typeInfo.instanceType,
					destination = output.type == Void ? -1 : requiredLocal(values, output.id),
					represented = calls == null ? UseDefault : calls.callClosure(typeInfo.staticType, instanceType, arguments,
						requiredLocal(values, closure.id), destination, [for (argument in arguments) requiredLocal(values, argument.id)]);
				if (emitIfHandled(body, represented)) {} else if (instanceType == null) {
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				} else {
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32And);
					body.push(If(null));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
					body.push(Else);
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(instanceType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
					body.push(End);
				}
			case InstanceClosure(output, name, receiver):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm instance closure target "$name" is not emitted';
				var tableSlot = context.tableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm instance closure target "$name" has no stable table slot';
				var calls = context.representation.calls,
					represented = calls == null ? UseDefault : calls.instanceClosure(name, context.tableSlots, requiredLocal(values, receiver.id),
						requiredLocal(values, output.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						I32Const(WasmLayout.CLOSURE_SIZE),
						Call(allocator),
						LocalTee(requiredLocal(values, output.id)),
						I32Const(WasmLayout.CLOSURE_TYPE_ID),
						I32Store(0),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(tableSlot),
						I32Store(WasmLayout.CLOSURE_FUNCTION_OFFSET),
						LocalGet(requiredLocal(values, output.id)),
						LocalGet(requiredLocal(values, receiver.id)),
						I32Store(WasmLayout.CLOSURE_RECEIVER_OFFSET)
					]);
			case ToVirtual(output, value):
				var represented = context.representation.values.toVirtual(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						LocalSet(requiredLocal(values, output.id))
					]);
			case MethodCall(output, object, methodName, arguments):
				switch object.type {
					case Obj(objectName):
						var targets = classVirtualTargets(context.program, objectName, methodName, functions),
							calls = context.representation.calls,
							represented = targets.length == 0
								|| calls == null ? UseDefault : calls.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
									output.type == Void ? -1 : requiredLocal(values, output.id),
									[for (argument in arguments) requiredLocal(values, argument.id)]);
						if (emitIfHandled(body, represented)) {} else if (targets.length == 0) {
							var functionName = findMethod(context.program, objectName, methodName),
								functionIndex = functionName == null ? null : functions.get(functionName);
							if (functionIndex == null)
								throw 'Wasm method target "$objectName.$methodName" is not emitted';
							body.push(LocalGet(requiredLocal(values, object.id)));
							for (argument in arguments)
								body.push(LocalGet(requiredLocal(values, argument.id)));
							body.push(Call(functionIndex));
							if (output.type != Void)
								body.push(LocalSet(requiredLocal(values, output.id)));
						} else {
							for (index in 0...targets.length) {
								var target = targets[index];
								emit(body, [
									LocalGet(requiredLocal(values, object.id)),
									I32Load(0),
									I32Const(typeId(Obj(target.typeName))),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, object.id))
								]);
								for (argument in arguments)
									body.push(LocalGet(requiredLocal(values, argument.id)));
								body.push(Call(target.functionIndex));
								if (output.type != Void)
									body.push(LocalSet(requiredLocal(values, output.id)));
								if (index < targets.length - 1)
									body.push(Else);
								else
									emit(body, [Else, Unreachable]);
							}
							for (_ in targets)
								body.push(End);
						}
					case Virtual(interfaceName):
						var targets = virtualTargets(context.program, interfaceName, methodName, functions);
						if (targets.length == 0) {
							// The closed-world program contains no concrete implementation for
							// this interface method. Preserve the language's invalid-dispatch
							// trap without requiring an otherwise-unused implementation class.
							body.push(Unreachable);
						}
						var calls = context.representation.calls,
							represented = calls == null ? UseDefault : calls.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
								output.type == Void ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]);
						if (emitIfHandled(body, represented)) {} else {
							for (index in 0...targets.length) {
								var target = targets[index];
								emit(body, [
									LocalGet(requiredLocal(values, object.id)),
									I32Load(0),
									I32Const(typeId(Obj(target.typeName))),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, object.id))
								]);
								for (argument in arguments)
									body.push(LocalGet(requiredLocal(values, argument.id)));
								body.push(Call(target.functionIndex));
								if (output.type != Void)
									body.push(LocalSet(requiredLocal(values, output.id)));
								if (index < targets.length - 1)
									body.push(Else);
								else
									emit(body, [Else, Unreachable]);
							}
							for (_ in targets)
								body.push(End);
						}
					default:
						throw 'Wasm method call requires an object or virtual receiver';
				}
			case ConstString(output, value):
				var represented = context.representation.values.constantString(value, requiredLocal(values, output.id), strings);
				if (emitIfHandled(body, represented)) {} else {
					var pointer = strings.get(value);
					if (pointer == null)
						throw 'Wasm string literal was not placed in a data segment';
					emit(body, [I32Const(pointer), LocalSet(requiredLocal(values, output.id))]);
				}
			case StaticDataAddress(output, bytes):
				var address = context.staticDataAddresses.get(WasmModuleSupport.staticDataKey(bytes));
				if (address == null)
					throw "Wasm static data address was not placed in the data section";
				emit(body, [I32Const(address), LocalSet(requiredLocal(values, output.id))]);
			case MakeEnum(output, typeName, constructor, arguments):
				var represented = context.representation.aggregates.makeEnum(typeName, constructor, arguments, requiredLocal(values, output.id),
					[for (argument in arguments) requiredLocal(values, argument.id)]);
				if (emitIfHandled(body, represented)) {} else {
					var enumLayout = layout.enumType(typeName);
					emit(body, [
						I32Const(enumLayout.size),
						Call(allocator),
						LocalTee(requiredLocal(values, output.id)),
						I32Const(typeId(Enum(typeName))),
						I32Store(0),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(constructor),
						I32Store(WasmLayout.HEADER_SIZE)
					]);
					var offset = WasmLayout.HEADER_SIZE + 4;
					for (argument in arguments) {
						offset = align(offset, WasmLayout.alignmentOf(argument.type));
						emit(body, [
							LocalGet(requiredLocal(values, output.id)),
							I32Const(offset),
							I32Add,
							LocalGet(requiredLocal(values, argument.id)),
							store(argument.type, 0)
						]);
						offset += WasmLayout.sizeOf(argument.type);
					}
				}
			case EnumIndex(output, value):
				var represented = context.representation.aggregates.enumIndex(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						I32Load(WasmLayout.HEADER_SIZE),
						LocalSet(requiredLocal(values, output.id))
					]);
			case EnumField(output, value, constructor, field):
				var represented = context.representation.aggregates.enumField(value, constructor, field, requiredLocal(values, output.id),
					requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else {
					var enumType = switch value.type {
						case Enum(name): name;
						default: throw 'Wasm enum field access requires an enum value, got ${Std.string(value.type)}';
					};
					var fieldLayout = layout.enumField(enumType, constructor, field);
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						I32Const(fieldLayout.offset),
						I32Add,
						load(fieldLayout.type, 0),
						LocalSet(requiredLocal(values, output.id))
					]);
				}
			case IntToFloat(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					value.type == I64 ? F64ConvertI64S : F64ConvertI32S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case IntToInt64(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					I64ExtendI32S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case FloatToInt(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					I32TruncF64S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case NewObject(output, typeName):
				emit(body, context.representation.aggregates.newObject(typeName, requiredLocal(values, output.id)));
			case FieldGet(output, object, fieldName):
				emit(body, context.representation.aggregates.fieldGet(object, fieldName, requiredLocal(values, output.id), requiredLocal(values, object.id)));
			case FieldSet(object, fieldName, value):
				emit(body, context.representation.aggregates.fieldSet(object, fieldName, requiredLocal(values, object.id), requiredLocal(values, value.id)));
			case ArrayGet(output, array, index):
				var represented = context.representation.aggregates.arrayGet(array, index, requiredLocal(values, output.id), requiredLocal(values, array.id),
					requiredLocal(values, index.id));
				if (emitIfHandled(body, represented)) {} else {
					var element = arrayElement(array),
						stride = WasmLayout.arrayStride(element);
					var arrayBody:Array<WasmInstruction> = [LocalGet(requiredLocal(values, index.id)), I32Const(0), I32LtS, If(null)];
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([
						Else,
						LocalGet(requiredLocal(values, index.id)),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						load(element, 0),
						LocalSet(requiredLocal(values, output.id)),
					]);
					arrayBody.push(Else);
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([End, End]);
					emit(body, arrayBody);
				}
			case ArraySet(array, index, value):
				var represented = context.representation.aggregates.arraySet(array, index, value, requiredLocal(values, array.id),
					requiredLocal(values, index.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else {
					var element = arrayElement(array),
						stride = WasmLayout.arrayStride(element);
					var arrayBody:Array<WasmInstruction> = [LocalGet(requiredLocal(values, index.id)), I32Const(0), I32LtS, If(null)];
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([
						Else,
						LocalGet(requiredLocal(values, index.id)),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						LocalGet(requiredLocal(values, value.id)),
						store(element, 0),
						Else
					]);
					arrayBody = arrayBody.concat([
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						LocalSet(context.arrayTemps.len),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(1),
						I32Add,
						LocalSet(context.arrayTemps.required),
						LocalGet(context.arrayTemps.required),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
						I32LeS,
						If(null),
						Else,
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
						I32Const(2),
						I32Mul,
						LocalSet(context.arrayTemps.capacity),
						LocalGet(context.arrayTemps.capacity),
						LocalGet(context.arrayTemps.required),
						I32LtS,
						If(null),
						LocalGet(context.arrayTemps.required),
						LocalSet(context.arrayTemps.capacity),
						End,
						LocalGet(context.arrayTemps.capacity),
						I32Const(stride),
						I32Mul,
						Call(allocator),
						LocalSet(context.arrayTemps.data),
						LocalGet(context.arrayTemps.data),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(context.arrayTemps.len),
						I32Const(stride),
						I32Mul,
						MemoryCopy,
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(context.arrayTemps.data),
						I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(context.arrayTemps.capacity),
						I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
						End,
						Block(null),
						Loop(null),
						LocalGet(context.arrayTemps.len),
						LocalGet(context.arrayTemps.required),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(context.arrayTemps.len),
						I32Const(stride),
						I32Mul,
						I32Add,
						element == F64 ? F64Const(0.0) : I32Const(0),
						element == F64 ? F64Store(0) : I32Store(0),
						LocalGet(context.arrayTemps.len),
						I32Const(1),
						I32Add,
						LocalSet(context.arrayTemps.len),
						Br(1),
						Else,
						Br(2),
						End,
						End,
						End,
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						LocalGet(requiredLocal(values, value.id)),
						store(element, 0),
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(context.arrayTemps.required),
						I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
						End,
						End
					]);
					emit(body, arrayBody);
				}
			case ArraySize(output, array):
				var represented = context.representation.aggregates.arraySize(array, requiredLocal(values, output.id), requiredLocal(values, array.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						LocalSet(requiredLocal(values, output.id))
					]);
			case IteratorNew(output, array):
				var iteratorLocal = requiredLocal(values, output.id),
					represented = context.representation.aggregates.iteratorNew(array, iteratorLocal, requiredLocal(values, array.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						I32Const(WasmLayout.ITERATOR_SIZE),
						Call(allocator),
						LocalTee(iteratorLocal),
						I32Const(typeId(IrType.Abstract("realtime_iterator"))),
						I32Store(0),
						LocalGet(iteratorLocal),
						I32Const(WasmLayout.ITERATOR_SIZE),
						I32Store(4),
						LocalGet(iteratorLocal),
						LocalGet(requiredLocal(values, array.id)),
						I32Store(WasmLayout.ITERATOR_ARRAY_OFFSET),
						LocalGet(iteratorLocal),
						I32Const(0),
						I32Store(WasmLayout.ITERATOR_POSITION_OFFSET)
					]);
			case IteratorHasNext(output, iterator):
				var iteratorLocal = requiredLocal(values, iterator.id),
					represented = context.representation.aggregates.iteratorHasNext(iterator, requiredLocal(values, output.id), iteratorLocal);
				if (emitIfHandled(body, represented)) {} else {
					var arrayOffset = WasmLayout.ITERATOR_ARRAY_OFFSET,
						positionOffset = WasmLayout.ITERATOR_POSITION_OFFSET;
					emit(body, [
						LocalGet(iteratorLocal),
						I32Eqz,
						If(I32),
						I32Const(0),
						Else,
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Eqz,
						If(I32),
						I32Const(0),
						Else,
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						End,
						End,
						LocalSet(requiredLocal(values, output.id))
					]);
				}
			case IteratorNext(output, iterator):
				var iteratorLocal = requiredLocal(values, iterator.id),
					represented = context.representation.aggregates.iteratorNext(iterator, output, requiredLocal(values, output.id), iteratorLocal);
				if (emitIfHandled(body, represented)) {} else {
					var arrayOffset = WasmLayout.ITERATOR_ARRAY_OFFSET,
						positionOffset = WasmLayout.ITERATOR_POSITION_OFFSET,
						stride = WasmLayout.arrayStride(output.type),
						outputLocal = requiredLocal(values, output.id);
					var iteratorBody:Array<WasmInstruction> = [LocalGet(iteratorLocal), I32Eqz, If(null)];
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([Else, LocalGet(iteratorLocal), I32Load(arrayOffset), I32Eqz, If(null)]);
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([
						Else,
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(stride),
						I32Mul,
						I32Add,
						load(output.type, 0),
						LocalSet(outputLocal),
						LocalGet(iteratorLocal),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(1),
						I32Add,
						I32Store(positionOffset),
						Else
					]);
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([End, End, End]);
					emit(body, iteratorBody);
				}
			case Add(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Add, I64Add, I32Add));
			case Sub(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Sub, I64Sub, I32Sub));
			case Mul(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Mul, I64Mul, I32Mul));
			case Div(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Div, I64DivS, I32DivS));
			case Mod(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32RemS, I64RemS, I32RemS));
			case BitAnd(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32And, I64And, I32And));
			case BitXor(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32Xor, I64Xor, I32Xor));
			case BitOr(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32Or, I64Or, I32Or));
			case ShiftLeft(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32Shl, I64Shl, I32Shl));
			case ShiftRight(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrS, I64ShrS, I32ShrS));
			case UnsignedShiftRight(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrU, I64ShrU, I32ShrU));
			case Less(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Lt, I64LtS, I32LtS));
			case LessEqual(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Le, I64LeS, I32LeS));
			case Equal(output, left, right):
				emit(body,
					context.representation.values.equal(requiredLocal(values, output.id), left, right, requiredLocal(values, left.id),
						requiredLocal(values, right.id)));
			case Call(output, name, arguments):
				var runtimeName = name;
				for (native in context.program.natives)
					if (native.name == name)
						runtimeName = native.symbol;
				var outputLocal = output.type == Void ? -1 : requiredLocal(values, output.id),
					interop = context.representation.interop,
					represented = interop == null ? UseDefault : interop.lowerRuntimeCall(runtimeName, output, arguments, outputLocal,
						[for (argument in arguments) requiredLocal(values, argument.id)]);
				if (emitIfHandled(body, represented)) {} else {
					var gcRuntime:WasmLoweringResult = Std.isOfType(context.representation.values,
						WasmGcRepresentation) ? cast(context.representation.values, WasmGcRepresentation).lowerRuntimeCall(runtimeName, output, arguments,
							outputLocal, [for (argument in arguments) requiredLocal(values, argument.id)]) : UseDefault;
					if (!emitIfHandled(body, gcRuntime) && !lowerInt64Native(body, output, name, arguments, values)) {
						for (argument in arguments)
							body.push(LocalGet(requiredLocal(values, argument.id)));
						var functionIndex = functions.get(name);
						var mapParts = WasmModuleSupport.mapNativeParts(name);
						if (mapParts != null && output.type != Void && (mapParts.operation == "keys" || mapParts.operation == "values")) {
							var projectionIndex = functions.get(WasmGcMaps.projectionName(name, output.type));
							if (projectionIndex != null)
								functionIndex = projectionIndex;
						}
						if (functionIndex == null)
							throw 'Wasm call to unsupported native or missing function "$name"';
						body.push(Call(functionIndex));
						if (output.type != Void)
							body.push(LocalSet(requiredLocal(values, output.id)));
					}
				}
			case CNativeCall(output, name, arguments):
				var native:Null<IrCNative> = null;
				for (candidate in context.program.cNatives)
					if (candidate.name == name)
						native = candidate;
				if (native == null)
					throw 'Wasm C native call "$name" has no declared import contract';
				var importIndex = functions.get(name);
				if (importIndex == null)
					throw 'Wasm C native call "$name" has no declared import contract';
				var pointerLengthImportIndex = -1,
					pointerReleaseImportIndex = -1;
				if ((native.result == ManagedBytes && native.pointerLength != null)
					|| (WasmModuleSupport.isGcNativePointerType(native.result) && native.pointerOwnership == "owned")) {
					var lengthNative:Null<IrCNative> = null;
					if (native.result == ManagedBytes && native.pointerLength != null) {
						for (candidate in context.program.cNatives)
							if (candidate.symbol == native.pointerLength)
								lengthNative = candidate;
						if (lengthNative != null) {
							var importedLength = functions.get(lengthNative.name);
							if (importedLength != null)
								pointerLengthImportIndex = importedLength;
						}
					}
					if (native.pointerOwnership == "owned" && native.pointerRelease != null)
						for (candidate in context.program.cNatives)
							if (candidate.symbol == native.pointerRelease) {
								var importedRelease = functions.get(candidate.name);
								if (importedRelease != null)
									pointerReleaseImportIndex = importedRelease;
							}
				}
				var outputLocal = output.type == Void ? -1 : requiredLocal(values, output.id),
					interop = context.representation.interop,
					represented = interop == null ? UseDefault : interop.lowerCNativeCall(native, arguments, outputLocal,
						[for (argument in arguments) requiredLocal(values, argument.id)], importIndex, pointerLengthImportIndex, pointerReleaseImportIndex);
				if (emitIfHandled(body, represented)) {} else {
					var bytesDataPointer = functions.get("__haxeon_bytes_data_pointer");
					if (bytesDataPointer == null)
						throw "Wasm byte data pointer helper is missing";
					for (argument in arguments)
						nativeArgument(body, argument, values, bytesDataPointer);
					body.push(Call(importIndex));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				}
		}
	}

	static function lowerInt64Native(body:Array<WasmInstruction>, output:IrValue, name:String, arguments:Array<IrValue>, values:Map<Int, Int>):Bool {
		if (name == "haxe.Int64.ofInt") {
			if (arguments.length != 1 || arguments[0].type != I32 || output.type != I64)
				throw "Invalid haxe.Int64.ofInt Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64ExtendI32S);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.toInt") {
			if (arguments.length != 1 || output.type != I32)
				throw "Invalid haxe.Int64.toInt Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I32WrapI64);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.compare") {
			if (arguments.length != 2 || output.type != I32)
				throw "Invalid haxe.Int64.compare Wasm native signature";
			var outputLocal = requiredLocal(values, output.id),
				leftLocal = requiredLocal(values, arguments[0].id),
				rightLocal = requiredLocal(values, arguments[1].id);
			body.push(LocalGet(leftLocal));
			body.push(LocalGet(rightLocal));
			body.push(I64LtS);
			body.push(If(null));
			body.push(I32Const(-1));
			body.push(LocalSet(outputLocal));
			body.push(Else);
			body.push(LocalGet(leftLocal));
			body.push(LocalGet(rightLocal));
			body.push(I64Eq);
			body.push(If(null));
			body.push(I32Const(0));
			body.push(LocalSet(outputLocal));
			body.push(Else);
			body.push(I32Const(1));
			body.push(LocalSet(outputLocal));
			body.push(End);
			body.push(End);
			return true;
		}
		if (name == "haxe.Int64.shl" || name == "haxe.Int64.shr" || name == "haxe.Int64.ushr") {
			if (arguments.length != 2 || output.type != I64)
				throw 'Invalid $name Wasm native signature';
			var valueLocal = requiredLocal(values, arguments[0].id),
				shiftLocal = requiredLocal(values, arguments[1].id),
				outputLocal = requiredLocal(values, output.id);
			body.push(LocalGet(shiftLocal));
			body.push(I32Const(0));
			body.push(I32LtS);
			body.push(LocalGet(shiftLocal));
			body.push(I32Const(64));
			body.push(I32LtS);
			body.push(I32Eqz);
			body.push(I32Or);
			body.push(If(null));
			if (name == "haxe.Int64.shr") {
				body.push(LocalGet(valueLocal));
				body.push(I64Const(0));
				body.push(I64LtS);
				body.push(If(null));
				body.push(I64Const(-1));
				body.push(LocalSet(outputLocal));
				body.push(Else);
				body.push(I64Const(0));
				body.push(LocalSet(outputLocal));
				body.push(End);
			} else {
				body.push(I64Const(0));
				body.push(LocalSet(outputLocal));
			}
			body.push(Else);
			body.push(LocalGet(valueLocal));
			body.push(LocalGet(shiftLocal));
			body.push(I64ExtendI32U);
			body.push(name == "haxe.Int64.shl" ? I64Shl : name == "haxe.Int64.shr" ? I64ShrS : I64ShrU);
			body.push(LocalSet(outputLocal));
			body.push(End);
			return true;
		}
		var operation = switch name {
			case "haxe.Int64.add": I64Add;
			case "haxe.Int64.sub": I64Sub;
			case "haxe.Int64.and": I64And;
			case "haxe.Int64.or": I64Or;
			case "haxe.Int64.xor": I64Xor;
			case _: null;
		};
		if (name == "haxe.Int64.make") {
			if (arguments.length != 2 || output.type != I64)
				throw "Invalid haxe.Int64.make Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64ExtendI32S);
			body.push(I64Const(32));
			body.push(I64Shl);
			body.push(LocalGet(requiredLocal(values, arguments[1].id)));
			body.push(I64ExtendI32U);
			body.push(I64Or);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (operation == null)
			return false;
		if (arguments.length != 2 || output.type != I64)
			throw 'Invalid $name Wasm native signature';
		body.push(LocalGet(requiredLocal(values, arguments[0].id)));
		body.push(LocalGet(requiredLocal(values, arguments[1].id)));
		body.push(operation);
		body.push(LocalSet(requiredLocal(values, output.id)));
		return true;
	}

	static function nativeArgument(body:Array<WasmInstruction>, argument:IrValue, values:Map<Int, Int>, bytesDataPointer:Int):Void {
		body.push(LocalGet(requiredLocal(values, argument.id)));
		switch argument.type {
			case Bytes, ManagedBytes:
				body.push(Call(bytesDataPointer));
			case IrType.Abstract("realtime_bytes"):
				body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
				body.push(I32Add);
			case _:
		}
	}

	static function objectField(layout:WasmLayout, object:IrValue, fieldName:String):WasmFieldLayout
		return switch object.type {
			case Obj(name): layout.field(name, fieldName);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};

	static function arrayElement(array:IrValue):IrType
		return switch array.type {
			case Array(element): element;
			default: throw 'Wasm array access requires an Array reference, got ${Std.string(array.type)}';
		};

	static function load(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Load(offset);
			case F64: F64Load(offset);
			default: I32Load(offset);
		};

	static function store(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Store(offset);
			case F64: F64Store(offset);
			default: I32Store(offset);
		};

	static function virtualTargets(program:IrProgram, interfaceName:String, methodName:String, functions:Map<String, Int>):Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}> {
		var result:Array<{
			typeName:String,
			functionIndex:Int,
			argumentTypes:Array<IrType>,
			resultType:IrType
		}> = [];
		for (object in program.objects) {
			if (!implementsInterface(program, object.name, interfaceName))
				continue;
			var functionName = findMethod(program, object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction:Null<IrFunction> = null;
				for (candidate in program.functions)
					if (candidate.name == functionName)
						targetFunction = candidate;
				if (functionIndex != null) {
					if (targetFunction == null)
						throw 'Wasm interface target "$functionName" has no Haxe function signature';
					result.push({
						typeName: object.name,
						functionIndex: functionIndex,
						argumentTypes: [for (argument in targetFunction.arguments) argument.type],
						resultType: targetFunction.result
					});
				}
			}
		}
		result.sort(function(left, right) return objectInheritanceDepth(program, right.typeName) - objectInheritanceDepth(program, left.typeName));
		return result;
	}

	static function classVirtualTargets(program:IrProgram, staticType:String, methodName:String, functions:Map<String, Int>):Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}> {
		var result:Array<{
			typeName:String,
			functionIndex:Int,
			argumentTypes:Array<IrType>,
			resultType:IrType
		}> = [];
		for (object in program.objects) {
			if (!isObjectSubtype(program, object.name, staticType))
				continue;
			var functionName = findMethod(program, object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction:Null<IrFunction> = null;
				for (candidate in program.functions)
					if (candidate.name == functionName)
						targetFunction = candidate;
				if (functionIndex != null) {
					if (targetFunction == null)
						throw 'Wasm class target "$functionName" has no Haxe function signature';
					result.push({
						typeName: object.name,
						functionIndex: functionIndex,
						argumentTypes: [for (argument in targetFunction.arguments) argument.type],
						resultType: targetFunction.result
					});
				}
			}
		}
		result.sort(function(left, right) return objectInheritanceDepth(program, right.typeName) - objectInheritanceDepth(program, left.typeName));
		return result;
	}

	static function isObjectSubtype(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (object in program.objects)
			if (object.name == actual)
				return object.base != null && isObjectSubtype(program, object.base, expected);
		return false;
	}

	static function objectInheritanceDepth(program:IrProgram, typeName:String):Int {
		for (object in program.objects)
			if (object.name == typeName)
				return object.base == null ? 0 : objectInheritanceDepth(program, object.base) + 1;
		return 0;
	}

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	public static function typeId(type:IrType):Int {
		var identity = switch type {
			case Iterator(_): IrType.Abstract("realtime_iterator");
			default: type;
		}, text = Std.string(identity), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	static function binary(body:Array<WasmInstruction>, output:IrValue, left:IrValue, right:IrValue, values:Map<Int, Int>, op:WasmInstruction):Void {
		emit(body, [
			LocalGet(requiredLocal(values, left.id)),
			LocalGet(requiredLocal(values, right.id)),
			op,
			LocalSet(requiredLocal(values, output.id))
		]);
	}

	static function shift(body:Array<WasmInstruction>, output:IrValue, left:IrValue, right:IrValue, values:Map<Int, Int>, op:WasmInstruction):Void {
		body.push(LocalGet(requiredLocal(values, left.id)));
		body.push(LocalGet(requiredLocal(values, right.id)));
		if (left.type == I64 && right.type == I32)
			body.push(I64ExtendI32U);
		body.push(op);
		body.push(LocalSet(requiredLocal(values, output.id)));
	}

	static function arithmeticInstruction(type:IrType, f64:WasmInstruction, i64:WasmInstruction, i32:WasmInstruction):WasmInstruction
		return switch type {
			case F64: f64;
			case I64: i64;
			default: i32;
		};

	static function comparisonInstruction(type:IrType, f64:WasmInstruction, i64:WasmInstruction, i32:WasmInstruction):WasmInstruction
		return switch type {
			case F64: f64;
			case I64: i64;
			default: i32;
		};

	static function rootPrologue(state:WasmFunctionGcRootState, rootLimit:Int):Array<WasmInstruction> {
		var result:Array<WasmInstruction> = [
			GlobalGet(state.top),
			I32Const(state.size),
			I32Add,
			I32Const(rootLimit),
			I32LeS,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			GlobalGet(state.top),
			LocalTee(state.frame),
			GlobalGet(state.top),
			I32Store(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET),
			LocalGet(state.frame),
			GlobalGet(state.frameTop),
			I32Store(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
			LocalGet(state.frame),
			I32Const(0),
			I32Store(WasmLayout.ROOT_COUNT_OFFSET),
			LocalGet(state.frame),
			I32Const(state.size),
			I32Add,
			GlobalSet(state.top),
			LocalGet(state.frame),
			GlobalSet(state.frameTop)
		];
		return result;
	}

	function snapshotRoots(body:Array<WasmInstruction>, ?block:Int = -1, ?instruction:Int = -1):Void {
		var rootState = context.gcRootState;
		if (rootState == null || block < 0 || instruction < 0)
			return;
		var state = rootState;
		var blockLive = state.live.get(block);
		if (blockLive == null)
			return;
		var live = blockLive.get(instruction);
		if (live == null)
			return;
		body.push(LocalGet(state.frame));
		body.push(I32Const(live.length));
		body.push(I32Store(WasmLayout.ROOT_COUNT_OFFSET));
		for (denseIndex in 0...live.length) {
			var valueId = live[denseIndex];
			var index = state.slotByValue.get(valueId);
			if (index == null)
				continue;
			body.push(LocalGet(state.frame));
			body.push(I32Const(WasmLayout.ROOT_VALUES_OFFSET + denseIndex * 4));
			body.push(I32Add);
			body.push(LocalGet(state.slots[index]));
			body.push(I32Store(0));
		}
	}

	function restoreRoots(body:Array<WasmInstruction>):Void {
		var rootState = context.gcRootState;
		if (rootState != null) {
			body.push(LocalGet(rootState.frame));
			body.push(I32Load(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET));
			body.push(GlobalSet(rootState.top));
			body.push(LocalGet(rootState.frame));
			body.push(I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
			body.push(GlobalSet(rootState.frameTop));
		}
	}

	static function emit(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function emitIfHandled(body:Array<WasmInstruction>, result:WasmLoweringResult):Bool {
		var kind:WasmLoweringKind = result;
		return switch kind {
			case Handled(instructions):
				emit(body, instructions);
				true;
			case UseDefault: false;
		};
	}

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), StaticDataAddress(output, _),
				ConstBool(output, _), PointerOffset(output, _, _), MemoryLoad(output, _, _, _), ConstNull(output), TypeValue(output, _), ToDyn(output, _),
				IntToFloat(output, _), IntToInt64(output, _), FloatToInt(output, _), SafeCast(output, _), Catch(output), GlobalGet(output, _),
				Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _), Mod(output, _, _), BitAnd(output, _, _), BitXor(output, _, _),
				BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _), UnsignedShiftRight(output, _, _), Less(output, _, _),
				LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _), CNativeCall(output, _, _), StaticClosure(output, _),
				InstanceClosure(output, _, _), CallClosure(output, _, _), ToVirtual(output, _), MethodCall(output, _, _, _), NewObject(output, _),
				FieldGet(output, _, _), ArrayGet(output, _, _), ArraySize(output, _), IteratorNew(output, _), IteratorHasNext(output, _),
				IteratorNext(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _), EnumField(output, _, _, _): output;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _), MemoryStore(_, _, _): null;
		};
}
