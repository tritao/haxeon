package compiler.backend.wasm;

import compiler.ir.IrProgramIndex;
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
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmFunctionLowerContext.WasmFunctionGcRootState;
import compiler.backend.wasm.WasmFunctionLowerContext.WasmFunctionExceptionState;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.gc.WasmGcRepresentation;
import compiler.backend.wasm.linear.WasmLinearRepresentation;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** One open Wasm structured-control instruction, innermost last. */
private enum StructureFrame {
	/** A `loop` whose header is the given block; a back edge to it is a `br` to this frame. */
	LoopFrame(header:Int);

	/** A `block` that ends where the given merge node's code begins. */
	BlockFrame(followedBy:Int);

	/** An `if`/`else`. */
	IfFrame;
}

/** Pending structured-control emission, held explicitly for arbitrarily deep CFGs. */
private enum StructureWork {
	Tree(id:Int);
	Within(id:Int, children:Array<Int>, count:Int);
	Edge(source:Int, target:Int);
	Close;
	Otherwise;
}

/** Everything one structured emission shares while it walks a function's dominator tree. */
private class StructuredEmission {
	public final structurer:WasmStructurer;
	public final functions:Map<String, Int>;
	public final values:Map<Int, Int>;
	public final predecessor:Int;
	public final layout:WasmLayout;
	public final allocator:Int;
	public final globals:Map<String, Int>;
	public final strings:Map<String, Int>;
	public final methods:Map<String, String>;
	public final closureTypes:Map<String, WasmClosureTypes>;
	public final frames:Array<StructureFrame> = [];
	public final phiBlocks:Map<Int, Bool> = [];

	public function new(structurer:WasmStructurer, functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, layout:WasmLayout, allocator:Int,
			globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>) {
		this.structurer = structurer;
		this.functions = functions;
		this.values = values;
		this.predecessor = predecessor;
		this.layout = layout;
		this.allocator = allocator;
		this.globals = globals;
		this.strings = strings;
		this.methods = methods;
		this.closureTypes = closureTypes;
	}

	/** The branch depth, counted from the innermost open frame, of the nearest frame matching `matches`. */
	public function depthOf(matches:StructureFrame->Bool):Int {
		var depth = 0, index = frames.length - 1;
		while (index >= 0) {
			if (matches(frames[index]))
				return depth;
			depth++;
			index--;
		}
		throw 'No enclosing frame for a branch in ${structurer.functionName}';
	}
}

class WasmFunctionLower {
	final context:WasmFunctionLowerContext;
	final nonNull:compiler.ir.IrNonNullFacts;

	function new(context:WasmFunctionLowerContext) {
		this.context = context;
		this.nonNull = new compiler.ir.IrNonNullFacts(context.irFunction);
	}

	static function requiredLocal(locals:Map<Int, Int>, valueId:Int):Int {
		if (!locals.exists(valueId))
			throw 'Unknown Wasm local for value $valueId';
		return locals.get(valueId);
	}

	static function requiredBlockIndex(blocks:Map<Int, Int>, blockId:Int):Int {
		if (!blocks.exists(blockId))
			throw 'Unknown Wasm block $blockId';
		return blocks.get(blockId);
	}

	public static function lower(module:WasmModule, fn:IrFunction, functions:Map<String, Int>, type:WasmFunctionType, layout:WasmLayout, allocator:Int,
			rootTop:Int, rootFrameTop:Int, rootLimit:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>, tableSlots:Map<String, Int>, exceptionTag:Null<Int>, rootPoints:Array<WasmSafepoint>,
			program:IrProgram, representation:WasmRepresentationSet, staticDataAddresses:Map<String, Int>, ?runtimeNeutral:Bool = false,
			?hasHaxeExceptions:Bool = false, ?pendingExceptionFlag:Null<Int>, ?pendingExceptionValue:Null<Int>):WasmFunction {
		var context = new WasmFunctionLowerContext(module, fn, program, representation, tableSlots, staticDataAddresses, exceptionTag, rootPoints,
			runtimeNeutral, hasHaxeExceptions, pendingExceptionFlag, pendingExceptionValue);
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
		var rootLocals:Array<Int> = [], rootIds:Map<Int, Bool> = [], live:Map<Int, Map<Int, Array<Int>>> = [], scalarRoots:Map<Int, Array<Int>> = [],
			synthetic = -1;
		if (Std.isOfType(context.representation.values, compiler.backend.wasm.linear.WasmLinearRepresentation)) {
			var linear:compiler.backend.wasm.linear.WasmLinearRepresentation = cast context.representation.values;
			for (owner => locals in linear.scalarReferenceLocals()) {
				var ids:Array<Int> = [];
				for (local in locals) {
					var id = synthetic--;
					valueLocals.set(id, local);
					ids.push(id);
				}
				scalarRoots.set(owner, ids);
			}
		}
		for (point in context.rootPoints) {
			var blockLive = live.get(point.block);
			if (blockLive == null) {
				blockLive = [];
				live.set(point.block, blockLive);
			}
			var references:Array<Int> = [];
			for (valueId in point.liveReferences)
				if (scalarRoots.exists(valueId))
					for (id in scalarRoots.get(valueId))
						references.push(id);
				else
					references.push(valueId);
			blockLive.set(point.instruction, references);
			for (valueId in references) {
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
		// In the neutral profile every function in an exception-enabled module needs a dispatcher: a callee can return a
		// pending exception to a caller that owns the active Haxe handler.
		context.exceptionState = null;
		var saved:Map<Int, Int> = [];
		if (context.exceptionTag != null || (context.runtimeNeutral && context.hasHaxeExceptions))
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case BeginTry(catchBlock, _, _):
							if (!saved.exists(catchBlock))
								saved.set(catchBlock, placement.allocate(I32));
						default:
					}
		if ((context.exceptionTag != null && saved.keys().hasNext()) || (context.runtimeNeutral && context.hasHaxeExceptions)) {
			var blocks:Map<Int, Int> = [], orderIndex = 0;
			for (id in analysis.graph.order)
				blocks.set(id, orderIndex++);
			context.exceptionState = {
				handler: placement.allocate(I32),
				exception: placement.allocate(context.representation.values.valueType(Dyn)),
				saved: saved,
				blocks: blocks,
				tag: context.exceptionTag
			};
		}
		var predecessor = placement.allocate(I32);
		var structurer = new WasmStructurer(fn),
			body:Array<WasmInstruction> = null;
		// Any reducible CFG structures, so a failure here is a bug to surface rather than a reason to emit the slow dispatcher.
		if (context.exceptionState == null && structurer.canUseStructured())
			body = lowerStructured(fn, structurer, functions, valueLocals, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		if (body == null) {
			var pc = placement.allocate(I32);
			body = lowerDispatcher(fn, analysis, functions, valueLocals, pc, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		}
		var rootState = context.gcRootState;
		if (rootState != null) {
			var rooted:Array<WasmInstruction> = rootPrologue(rootState, rootLimit);
			rooted = rooted.concat(body);
			if (context.exceptionTag != null && !context.runtimeNeutral) {
				var exceptionLocal = placement.allocate(context.representation.values.valueType(Dyn)),
					protectedBody:Array<WasmInstruction> = [Try(null)];
				protectedBody = protectedBody.concat(rooted);
				protectedBody = protectedBody.concat([Catch(context.exceptionTag), LocalSet(exceptionLocal)]);
				restoreRoots(protectedBody);
				protectedBody = protectedBody.concat([LocalGet(exceptionLocal), Throw(context.exceptionTag), End, Unreachable]);
				rooted = protectedBody;
			}
			body = rooted;
		}
		if (Std.isOfType(context.representation.values, WasmGcRepresentation)) {
			var gc:WasmGcRepresentation = cast context.representation.values,
				wrapped = gc.scalarExceptionWrapper(fn, body, valueLocals, context.exceptionTag);
			if (wrapped != null)
				body = wrapped;
		}
		if (Std.isOfType(context.representation.values, compiler.backend.wasm.linear.WasmLinearRepresentation)) {
			var linear:compiler.backend.wasm.linear.WasmLinearRepresentation = cast context.representation.values,
				cleanup:Array<WasmInstruction> = [];
			restoreRoots(cleanup);
			var wrapped = linear.scalarExceptionWrapper(fn, body, valueLocals, context.exceptionTag, cleanup);
			if (wrapped != null)
				body = wrapped;
		}
		body = WasmOptimizer.optimize(body);
		return new WasmFunction(fn.name, type, locals, body);
	}

	function lowerStructured(fn:IrFunction, structurer:WasmStructurer, functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, layout:WasmLayout,
			allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [],
			state = new StructuredEmission(structurer, functions, values, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		emit(body, [I32Const(-1), LocalSet(predecessor)]);
		// `predecessor` only matters on edges into a block with phis, so only those edges set it.
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Phi(output, _) if ((switch (output.type) {
						case Void: false;
						default: true;
					})):
						state.phiBlocks.set(block.id, true);
					default:
				}
		structuredTree(body, state, fn.blocks[0].id);
		body.push(Unreachable);
		return body;
	}

	/** Emit the dominator tree without consuming the compiler host's call stack. */
	function structuredTree(body:Array<WasmInstruction>, state:StructuredEmission, id:Int):Void {
		var pending:Array<StructureWork> = [Tree(id)];
		while (pending.length > 0)
			switch pending.pop() {
				case Tree(blockId):
					if (state.structurer.isLoopHeader(blockId)) {
						body.push(Loop(null));
						state.frames.push(LoopFrame(blockId));
						pending.push(Close);
					}
					var children = state.structurer.mergeChildrenOf(blockId);
					pending.push(Within(blockId, children, children.length));
				case Within(blockId, children, count):
					if (count > 0) {
						var last = children[count - 1];
						body.push(Block(null));
						state.frames.push(BlockFrame(last));
						pending.push(Tree(last));
						pending.push(Close);
						pending.push(Within(blockId, children, count - 1));
					} else {
						var block = state.structurer.analysis.graph.block(blockId);
						emitBlockInstructions(body, block, state.values, state.functions, state.predecessor, state.layout, state.allocator, state.globals,
							state.strings, state.methods, state.closureTypes);
						if (block.terminator == null)
							throw 'Reachable block $blockId has no terminator';
						switch block.terminator.value {
							case Unreachable: body.push(Unreachable);
							case Return(value):
								restoreRoots(body);
								if ((switch (value.type) {
									case Void: false;
									default: true;
								}))
									body.push(LocalGet(requiredLocal(state.values, value.id)));
								body.push(Return);
							case Throw(value), Rethrow(value): emitThrow(body, requiredLocal(state.values, value.id));
							case Jump(target): pending.push(Edge(blockId, target));
							case Branch(condition, yes, no):
								if (yes == no) pending.push(Edge(blockId, yes)); else {
									emit(body, [LocalGet(requiredLocal(state.values, condition.id)), If(null)]);
									state.frames.push(IfFrame);
									pending.push(Close);
									pending.push(Edge(blockId, no));
									pending.push(Otherwise);
									pending.push(Edge(blockId, yes));
								}
						}
					}
				case Edge(source, target):
					if (state.phiBlocks.exists(target))
						setPredecessor(body, state.predecessor, source);
					if (state.structurer.isBackEdge(source, target))
						body.push(Br(state.depthOf(frame -> switch frame {
							case LoopFrame(header): header == target;
							default: false;
						})));
					else if (state.structurer.isMergeNode(target))
						body.push(Br(state.depthOf(frame -> switch frame {
							case BlockFrame(followedBy): followedBy == target;
							default: false;
						})));
					else
						pending.push(Tree(target));
				case Close:
					state.frames.pop();
					body.push(End);
				case Otherwise:
					body.push(Else);
			}
	}

	function emitBlockInstructions(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		emitPhiGroup(body, block, values, predecessor);
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			// Safepoint liveness describes the instruction's entry state; snapshot before it can allocate or collect.
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(_, _):
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes,
						nonNull.has(block.id, index));
			}
		}
	}

	function emitPhiGroup(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, predecessor:Int):Void {
		var staged:Array<{target:Int, temporary:Int}> = [];
		for (located in block.instructions)
			switch located.value {
				// A Void join (branches whose results are discarded) carries no value; placement gives it no local.
				case Phi(output, _) if ((switch (output.type) {
					case Void: true;
					default: false;
				})):
				case Phi(output, inputs):
					var temporary = context.placement.allocate(context.representation.values.valueType(output.type));
					WasmPhiLower.capture(body, inputs, values, predecessor, temporary);
					staged.push({target: requiredLocal(values, output.id), temporary: temporary});
				default:
			}
		for (entry in staged)
			emit(body, [LocalGet(entry.temporary), LocalSet(entry.target)]);
	}

	function lowerDispatcher(fn:IrFunction, analysis:WasmCfgAnalysis, functions:Map<String, Int>, values:Map<Int, Int>, pc:Int, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [], blockIndex:Map<Int, Int> = [];
		var next = 0;
		for (id in analysis.graph.order)
			blockIndex.set(id, next++);
		var exceptionState = context.exceptionState,
			exceptionTag = exceptionState == null ? null : exceptionState.tag,
			usesWasmExceptions = exceptionState != null && exceptionTag != null;
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
		if (usesWasmExceptions)
			body.push(Try(null));
		else if (context.runtimeNeutral && exceptionState != null)
			emitPendingExceptionDispatch(body, fn, pc, exceptionState);
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
		if (exceptionState == null || exceptionTag == null) {
			emit(body, [Br(0), End, End, Unreachable]);
		} else {
			emit(body, [Br(1), Catch(exceptionTag), LocalSet(exceptionState.exception)]);
			emit(body, [LocalGet(exceptionState.handler), I32Const(-1), I32Eq, If(null)]);
			emit(body, [LocalGet(exceptionState.exception), Throw(exceptionTag), Else]);
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

	function emitPendingExceptionDispatch(body:Array<WasmInstruction>, fn:IrFunction, pc:Int, exceptionState:WasmFunctionExceptionState):Void {
		body.push(GlobalGet(requiredPendingExceptionFlag()));
		body.push(If(null));
		emit(body, [LocalGet(exceptionState.handler), I32Const(-1), I32Eq, If(null)]);
		restoreRoots(body);
		var linear:Null<compiler.backend.wasm.linear.WasmLinearRepresentation> = Std.isOfType(context.representation.values,
			compiler.backend.wasm.linear.WasmLinearRepresentation) ? cast context.representation.values : null,
			signature = linear == null ? null : linear.scalarSignature(fn.name);
		if (signature != null && signature.throwsReceiver) {
			emit(body, [
				GlobalGet(requiredPendingExceptionValue()), LocalSet(exceptionState.exception),                              I32Const(0),
				 GlobalSet(requiredPendingExceptionFlag()),                        I32Const(0), GlobalSet(requiredPendingExceptionValue())
			]);
			emit(body, linear.scalarExceptionResult(fn, context.valueLocals, exceptionState.exception));
		} else if (signature != null) {
			for (type in linear.scalarReturnTypes(signature))
				emit(body, context.representation.values.zeroValue(type));
		} else
			emit(body, context.representation.values.zeroValue(fn.result));
		body.push(Return);
		body.push(Else);
		emit(body, [
			GlobalGet(requiredPendingExceptionValue()),
			LocalSet(exceptionState.exception),
			I32Const(0),
			GlobalSet(requiredPendingExceptionFlag()),
			I32Const(0),
			GlobalSet(requiredPendingExceptionValue())
		]);
		var catches = [for (catchBlock in exceptionState.saved.keys()) catchBlock];
		catches.sort(function(left, right) return left - right);
		for (index in 0...catches.length) {
			var catchBlock = catches[index];
			emit(body, [
				LocalGet(exceptionState.handler),
				I32Const(requiredBlockIndex(exceptionState.blocks, catchBlock)),
				I32Eq,
				If(null)
			]);
			emit(body, [
				LocalGet(exceptionState.handler),
				LocalSet(pc),
				LocalGet(requiredLocal(exceptionState.saved, catchBlock)),
				LocalSet(exceptionState.handler),
				Br(index + 3)
			]);
			body.push(Else);
		}
		body.push(Unreachable);
		for (_ in catches)
			body.push(End);
		body.push(End);
		body.push(End);
	}

	public static function hasExceptions(fn:IrFunction):Bool {
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
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
		var dispatchIndex = requiredBlockIndex(blockIndex, block.id);
		context.exceptionDispatchIndex = dispatchIndex;
		emitPhiGroup(body, block, values, predecessor);
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(_, _):
				default:
					var start = body.length;
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes,
						nonNull.has(block.id, index));
					if (context.runtimeNeutral && context.exceptionState != null && containsCall(body.slice(start)))
						emitPendingCallBranch(body, dispatchIndex);
			}
		}
		if (block.terminator == null)
			throw 'Missing terminator in Wasm block ${block.id}';
		switch block.terminator.value {
			case Unreachable:
				body.push(Unreachable);
			case Return(value):
				restoreRoots(body);
				if ((switch (value.type) {
					case Void: false;
					default: true;
				}))
					body.push(LocalGet(requiredLocal(values, value.id)));
				body.push(Return);
			case Throw(value), Rethrow(value):
				if (context.runtimeNeutral && context.exceptionState != null)
					emitNeutralThrow(body, requiredLocal(values, value.id), dispatchIndex);
				else
					emitThrow(body, requiredLocal(values, value.id));
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

	function trapOrThrow(extraIfs:Int = 0):Array<WasmInstruction> {
		var tag = context.exceptionTag;
		if (tag != null)
			return context.representation.values.zeroValue(Dyn).concat([Throw(tag)]);
		if (!context.runtimeNeutral || context.exceptionState == null)
			return [Unreachable];
		return [
			I32Const(0),
			GlobalSet(requiredPendingExceptionValue()),
			I32Const(1),
			GlobalSet(requiredPendingExceptionFlag()),
			Br(context.exceptionDispatchIndex + 1 + extraIfs)
		];
	}

	/** A Haxe throw: the module's exception tag when it has exceptions, otherwise a trap. */
	function emitThrow(body:Array<WasmInstruction>, valueLocal:Int):Void {
		var tag = context.exceptionTag;
		if (context.runtimeNeutral && context.exceptionState != null)
			emitNeutralThrow(body, valueLocal, context.exceptionDispatchIndex);
		else if (tag == null)
			body.push(Unreachable);
		else
			emit(body, [LocalGet(valueLocal), Throw(tag)]);
	}

	function emitNeutralThrow(body:Array<WasmInstruction>, valueLocal:Int, dispatchIndex:Int):Void
		emit(body, [
			LocalGet(valueLocal),
			GlobalSet(requiredPendingExceptionValue()),
			I32Const(1),
			GlobalSet(requiredPendingExceptionFlag()),
			Br(dispatchIndex + 1)
		]);

	function emitPendingCallBranch(body:Array<WasmInstruction>, dispatchIndex:Int):Void
		emit(body, [GlobalGet(requiredPendingExceptionFlag()), If(null), Br(dispatchIndex + 2), End]);

	function requiredPendingExceptionFlag():Int {
		if (context.pendingExceptionFlag == null)
			throw "Runtime-neutral exception flag was not initialized";
		return context.pendingExceptionFlag;
	}

	function requiredPendingExceptionValue():Int {
		if (context.pendingExceptionValue == null)
			throw "Runtime-neutral exception payload was not initialized";
		return context.pendingExceptionValue;
	}

	static function containsCall(instructions:Array<WasmInstruction>):Bool {
		for (instruction in instructions)
			switch instruction {
				case Call(_) | CallIndirect(_):
					return true;
				default:
			}
		return false;
	}

	static function setPredecessor(body:Array<WasmInstruction>, predecessor:Int, sourceBlock:Int):Void
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor)]);

	function lowerInstruction(body:Array<WasmInstruction>, instruction:IrInstruction, values:Map<Int, Int>, functions:Map<String, Int>, layout:WasmLayout,
			allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>,
			?knownNonNull:Bool = false):Void {
		if (Std.isOfType(context.representation.values, WasmGcRepresentation)) {
			var gc:WasmGcRepresentation = cast context.representation.values,
				scalar = gc.scalarLocal(instruction, values);
			if (scalar != null) {
				emit(body, scalar);
				return;
			}
		}
		if (Std.isOfType(context.representation.values, compiler.backend.wasm.linear.WasmLinearRepresentation)) {
			var linear:compiler.backend.wasm.linear.WasmLinearRepresentation = cast context.representation.values,
				scalar = linear.scalarLocal(instruction, values);
			if (scalar != null) {
				emit(body, scalar);
				return;
			}
		}
		var exceptionState = context.exceptionState;
		switch instruction {
			case Phi(_, _):
			case ClassId(_, _):
				throw 'internal error: ClassId is lowered by the interface dispatch (docs/INTERFACE_VALUES.md), which Wasm does not have yet';
			case PointerOffset(output, pointer, byteOffset):
				emit(body, [
					LocalGet(requiredLocal(values, pointer.id)),
					LocalGet(requiredLocal(values, byteOffset.id)),
					I32Add,
					LocalSet(requiredLocal(values, output.id))
				]);
			case MemoryLoad(output, pointer, size, signed):
				var load:Array<WasmInstruction> = switch output.type {
					case F32: [F32Load(0), F64PromoteF32];
					case F64: [F64Load(0)];
					case I64: [I64Load(0)];
					default: switch size {
							case 1: [signed ? I32Load8S(0) : I32Load8U(0)];
							case 2: [signed ? I32Load16S(0) : I32Load16U(0)];
							case 4: [I32Load(0)];
							default: throw 'Unsupported Wasm raw memory load size $size';
						};
				};
				emit(body, [LocalGet(requiredLocal(values, pointer.id))].concat(load).concat([LocalSet(requiredLocal(values, output.id))]));
			case MemoryStore(pointer, value, size):
				var store:Array<WasmInstruction> = switch value.type {
					case F32: [F32DemoteF64, F32Store(0)];
					case F64: [F64Store(0)];
					case I64: [I64Store(0)];
					default: switch size {
							case 1: [I32Store8(0)];
							case 2: [I32Store16(0)];
							case 4: [I32Store(0)];
							default: throw 'Unsupported Wasm raw memory store size $size';
						};
				};
				emit(body, [
					LocalGet(requiredLocal(values, pointer.id)),
					LocalGet(requiredLocal(values, value.id))
				].concat(store));
			case ConstInt(output, value):
				emit(body, [
					(switch (output.type) {
						case I64: true;
						default: false;
					})
					? I64Const(value) : I32Const(value),
					LocalSet(requiredLocal(values, output.id))
				]);
			case ConstBool(output, value):
				emit(body, [I32Const(value ? 1 : 0), LocalSet(requiredLocal(values, output.id))]);
			case ConstFloat(output, value):
				emit(body, [F64Const(value), LocalSet(requiredLocal(values, output.id))]);
			case ConstNull(output) if (switch output.type {
					case EnumTag(_): true;
					default: false;
				}):
				emit(body, [I32Const(0), LocalSet(requiredLocal(values, output.id))]);
			case ConstNull(output):
				emit(body, context.representation.values.nullValue(output.type, requiredLocal(values, output.id)));
			case ConstVoid(_):
			case TypeValue(output, type):
				emit(body, [I32Const(typeId(type)), LocalSet(requiredLocal(values, output.id))]);
			case ToDyn(output, value):
				var represented = context.representation.values.toDynamic(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, boxedValue(value.type, requiredLocal(values, value.id), requiredLocal(values, output.id), allocator));
			case SafeCast(output, value):
				var represented = context.representation.values.safeCast(output, value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else
					switch output.type {
						case Function(_, _)
							if (Std.isOfType(context.representation.values, WasmLinearRepresentation)
								&& functions.exists((cast context.representation.values : WasmLinearRepresentation).closureAdapters.castName(output.type))):
							// A closure created with another representation is adapted (WasmLinearClosureAdapters).
							emit(body, [
								LocalGet(requiredLocal(values, value.id)),
								Call(WasmModuleSupport.requiredFunctionIndex(functions,
									(cast context.representation.values : WasmLinearRepresentation).closureAdapters.castName(output.type))),
								LocalSet(requiredLocal(values, output.id))
							]);
						case Function(_, _) if (Std.isOfType(context.representation.values, WasmLinearRepresentation)):
							throw 'Missing reachable Wasm32 closure cast helper for ${Std.string(output.type)}';
						case I32, F64 if ((switch (value.type) {
							case Dyn: true;
							default: false;
						})):
							// Any boxed number converts to Int or Float, as on HashLink: JSON gives an Int box for a whole number.
							emit(body, dynamicNumber(output.type, requiredLocal(values, value.id), requiredLocal(values, output.id)));
						case Bool, I64 if ((switch (value.type) {
							case Dyn: true;
							default: false;
						})):
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
						case RawPtr | TypeRef | Abstract("native_callback") if ((switch (value.type) {
							case Dyn: true;
							default: false;
						})):
							var source = requiredLocal(values, value.id),
								destination = requiredLocal(values, output.id);
							emit(body, [
								LocalGet(source),
								I32Eqz,
								If(null),
								I32Const(0),
								LocalSet(destination),
								Else,
								LocalGet(source),
								I32Const(1),
								I32And,
								If(null)
							].concat(trapOrThrow(2)).concat([
								End,
								LocalGet(source),
								I32Load(0),
								I32Const(typeId(output.type)),
								I32Eq,
								If(null),
								LocalGet(source),
								I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
								LocalSet(destination),
								Else
								]).concat(trapOrThrow(2)).concat([End, End]));
						default:
							emit(body, [
								LocalGet(requiredLocal(values, value.id)),
								LocalSet(requiredLocal(values, output.id))
							]);
					}
			case BeginTry(catchBlock, _, _):
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
			case EndTry(catchBlock, _):
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
					represented = calls == null ? UseDefault : calls.staticClosure(name, output.type, context.tableSlots, requiredLocal(values, output.id));
				if (emitIfHandled(body, represented)) {} else {
					var linear:WasmLinearRepresentation = cast context.representation.values;
					var descriptor = linear.staticClosureDescriptors.get(compiler.backend.wasm.linear.WasmLinearClosureAdapters.staticDescriptorKey(name,
						output.type));
					if (descriptor == null)
						throw 'Missing static closure descriptor for $name';
					emit(body, [I32Const(descriptor | 1), LocalSet(requiredLocal(values, output.id))]);
				}
			case CallClosure(output, closure, arguments):
				var typeInfo = closureTypes.get(Std.string(closure.type));
				if (typeInfo == null)
					throw 'Wasm closure type ${Std.string(closure.type)} has no indirect signature';
				var scalarGc:Null<WasmGcRepresentation> = Std.isOfType(context.representation.values,
					WasmGcRepresentation) ? cast(context.representation.values, WasmGcRepresentation) : null;
				if (scalarGc != null && scalarGc.hasScalarClosure(closure.type)) {
					if (typeInfo.instanceType == null)
						throw "Scalar closure has no instance ABI";
					emit(body,
						scalarGc.scalarClosureCall(closure.type, typeInfo.staticType, typeInfo.instanceType, requiredLocal(values, closure.id), output,
							(switch (output.type) {
								case Void: true;
								default: false;
							}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]));
					return;
				}
				var scalarLinear:Null<WasmLinearRepresentation> = Std.isOfType(context.representation.values,
					WasmLinearRepresentation) ? cast(context.representation.values, WasmLinearRepresentation) : null;
				if (scalarLinear != null && scalarLinear.hasScalarClosure(closure.type)) {
					if (typeInfo.instanceType == null)
						throw "Scalar closure has no instance ABI";
					emit(body,
						scalarLinear.scalarClosureCall(closure.type, typeInfo.staticType, typeInfo.instanceType, requiredLocal(values, closure.id), output,
							(switch (output.type) {
								case Void: true;
								default: false;
							}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]));
					return;
				}
				var calls = context.representation.calls,
					instanceType = typeInfo.instanceType,
					destination = (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values, output.id),
					represented = calls == null ? UseDefault : calls.callClosure(typeInfo.staticType, instanceType, arguments,
						requiredLocal(values, closure.id), destination, [for (argument in arguments) requiredLocal(values, argument.id)]);
				if (emitIfHandled(body, represented)) {} else if (instanceType == null) {
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(-2));
					body.push(I32And);
					body.push(I32Load(WasmLayout.STATIC_CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(typeInfo.staticType));
					if ((switch (output.type) {
						case Void: false;
						default: true;
					}))
						body.push(LocalSet(requiredLocal(values, output.id)));
				} else {
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32And);
					body.push(If(null));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(-2));
					body.push(I32And);
					body.push(I32Load(WasmLayout.STATIC_CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(typeInfo.staticType));
					if ((switch (output.type) {
						case Void: false;
						default: true;
					}))
						body.push(LocalSet(requiredLocal(values, output.id)));
					body.push(Else);
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(instanceType));
					if ((switch (output.type) {
						case Void: false;
						default: true;
					}))
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
					represented = calls == null ? UseDefault : calls.instanceClosure(name, output.type, context.tableSlots,
						requiredLocal(values, receiver.id), requiredLocal(values, output.id));
				if (emitIfHandled(body, represented)) {} else {
					var linear:WasmLinearRepresentation = cast context.representation.values;
					if (linear.closureAdapters == null)
						throw "Missing Wasm32 closure signatures";
					emit(body, [
						I32Const(WasmLayout.CLOSURE_SIZE),
						Call(allocator),
						LocalTee(requiredLocal(values, output.id)),
						I32Const(WasmLayout.CLOSURE_TYPE_ID),
						I32Store(0),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(name == WasmDynamicCalls.VARARGS_TARGET ? -1 : linear.closureAdapters.signatureId(output.type)),
						I32Store(WasmLayout.CLOSURE_SIGNATURE_OFFSET),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(tableSlot),
						I32Store(WasmLayout.CLOSURE_FUNCTION_OFFSET),
						LocalGet(requiredLocal(values, output.id)),
						LocalGet(requiredLocal(values, receiver.id)),
						I32Store(WasmLayout.CLOSURE_RECEIVER_OFFSET)
					]);
				}
			case Upcast(output, value):
				// Object types declare their base class as their supertype.
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					LocalSet(requiredLocal(values, output.id))
				]);
			case ToVirtual(output, value):
				var represented = context.representation.values.toVirtual(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (emitIfHandled(body, represented)) {} else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						LocalSet(requiredLocal(values, output.id))
					]);
			case MethodCall(output, object, methodName, arguments, _):
				// Dispatch must fail as a Haxe exception before reading the receiver's type or calling its method.
				var receiverCheck:Array<WasmInstruction> = [
					LocalGet(requiredLocal(values, object.id)),
					Std.isOfType(context.representation.values, WasmGcRepresentation) ? RefIsNull : I32Eqz,
					If(null)
				];
				if (!knownNonNull)
					emit(body, receiverCheck.concat(trapOrThrow(1)).concat([End]));
				var scalarGc:Null<WasmGcRepresentation> = Std.isOfType(context.representation.values,
					WasmGcRepresentation) ? cast(context.representation.values, WasmGcRepresentation) : null;
				if (scalarGc != null && scalarGc.hasScalarVirtual(object.type, methodName)) {
					emit(body, scalarGc.scalarVirtualCall(object, methodName, requiredLocal(values, object.id), output, (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values, output.id), arguments, [for (argument in arguments) requiredLocal(values, argument.id)]));
					return;
				}
				var scalarLinear:Null<compiler.backend.wasm.linear.WasmLinearRepresentation> = Std.isOfType(context.representation.values,
					compiler.backend.wasm.linear.WasmLinearRepresentation) ? cast context.representation.values : null;
				if (scalarLinear != null && scalarLinear.hasScalarVirtual(object.type, methodName)) {
					emit(body, scalarLinear.scalarVirtualCall(object, methodName, requiredLocal(values, object.id), output, (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values, output.id), arguments, [for (argument in arguments) requiredLocal(values, argument.id)]));
					return;
				}
				switch object.type {
					case Obj(objectName):
						var targets = classVirtualTargets(context.program, objectName, methodName, functions),
							calls = context.representation.calls,
							represented = targets.length == 0
								|| calls == null ? UseDefault : calls.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
									(switch (output.type) {
										case Void: true;
										default: false;
									}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]);
						if (emitIfHandled(body, represented)) {} else if (targets.length == 0) {
							var functionName = findMethod(context.program, objectName, methodName),
								functionIndex = functionName == null ? null : functions.get(functionName);
							if (functionIndex == null) {
								// Dispatch reaches the methods of constructed classes only (IrReachability): no class that could receive
								// this call has an instance, so like an interface method without an implementation it traps.
								body.push(Unreachable);
							} else {
								body.push(LocalGet(requiredLocal(values, object.id)));
								for (argument in arguments)
									body.push(LocalGet(requiredLocal(values, argument.id)));
								body.push(Call(functionIndex));
								if ((switch (output.type) {
									case Void: false;
									default: true;
								}))
									body.push(LocalSet(requiredLocal(values, output.id)));
							}
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
								if ((switch (output.type) {
									case Void: false;
									default: true;
								}))
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
								(switch (output.type) {
									case Void: true;
									default: false;
								}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]);
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
								for (argumentIndex in 0...arguments.length)
									emit(body,
										adaptInterfaceValue(arguments[argumentIndex].type, target.argumentTypes[argumentIndex + 1],
											requiredLocal(values, arguments[argumentIndex].id), allocator, index + 1));
								body.push(Call(target.functionIndex));
								if ((switch (output.type) {
									case Void: false;
									default: true;
								})) {
									var result = context.placement.allocate(WasmModuleSupport.requireValueType(target.resultType));
									body.push(LocalSet(result));
									emit(body, adaptInterfaceValue(target.resultType, output.type, result, allocator, index + 1));
									body.push(LocalSet(requiredLocal(values, output.id)));
								}
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
			case MakeEnum(output, _, constructor, _) if (switch output.type {
					case EnumTag(_): true;
					default: false;
				}):
				emit(body, [I32Const(constructor + 1), LocalSet(requiredLocal(values, output.id))]);
			case MakeEnum(output, typeName, constructor, arguments):
				var represented = context.representation.aggregates.makeEnum(typeName, constructor, arguments, requiredLocal(values, output.id),
					[for (argument in arguments) requiredLocal(values, argument.id)]);
				if (emitIfHandled(body, represented)) {} else {
					var enumLayout = layout.enumType(typeName);
					var cache:Null<Int> = arguments.length == 0 ? WasmModuleSupport.requiredGlobal(globals,
						WasmModuleSupport.enumCaseKey(typeName, constructor)) : null;
					if (cache != null) {
						emit(body, [GlobalGet(cache), LocalTee(requiredLocal(values, output.id)), I32Eqz, If(null)]);
					}
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
					if (cache != null)
						emit(body, [LocalGet(requiredLocal(values, output.id)), GlobalSet(cache), End]);
				}
			case EnumIndex(output, value) if (switch value.type {
					case EnumTag(_): true;
					default: false;
				}):
				emit(body, [LocalGet(requiredLocal(values, value.id)), I32Eqz, If(null)].concat(trapOrThrow(1)).concat([
					End,
					LocalGet(requiredLocal(values, value.id)),
					I32Const(1),
					I32Sub,
					LocalSet(requiredLocal(values, output.id))
				]));
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
					(switch (value.type) {
						case I64: true;
						default: false;
					})
					? F64ConvertI64S : F64ConvertI32S,
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
			case FloatToFloat(output, value):
				var conversion:Array<WasmInstruction> = (switch (value.type) {
					case F64: true;
					default: false;
				}) ? [F32DemoteF64, F64PromoteF32] : [];
				emit(body, [LocalGet(requiredLocal(values, value.id))].concat(conversion).concat([LocalSet(requiredLocal(values, output.id))]));
			case NewObject(output, typeName):
				emit(body, context.representation.aggregates.newObject(typeName, requiredLocal(values, output.id)));
			case FieldGet(output, object, fieldName) if (fieldName == compiler.backend.wasm.WasmFlattenValueFields.CHECK_FIELD):
				var check:Array<WasmInstruction> = [
					LocalGet(requiredLocal(values, object.id)),
					Std.isOfType(context.representation.values, WasmGcRepresentation) ? RefIsNull : I32Eqz,
					If(null)
				];
				check = check.concat(trapOrThrow(1)).concat([End, I32Const(0), LocalSet(requiredLocal(values, output.id))]);
				emit(body, check);
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
					arrayBody = arrayBody.concat(trapOrThrow(1));
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
					arrayBody = arrayBody.concat(trapOrThrow(2));
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
					arrayBody = arrayBody.concat(trapOrThrow(1));
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
						(switch (element) {
							case F64: true;
							default: false;
						})
						? F64Const(0.0) : I32Const(0),
						(switch (element) {
							case F64: true;
							default: false;
						})
						? F64Store(0) : I32Store(0),
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
						I32Const(typeId(Abstract("realtime_iterator"))),
						I32Store(0),
						LocalGet(iteratorLocal),
						I32Const(typeId(output.type)),
						I32Store(WasmLayout.ITERATOR_TYPE_OFFSET),
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
					iteratorBody = iteratorBody.concat(trapOrThrow(1));
					iteratorBody = iteratorBody.concat([Else, LocalGet(iteratorLocal), I32Load(arrayOffset), I32Eqz, If(null)]);
					iteratorBody = iteratorBody.concat(trapOrThrow(2));
					iteratorBody = iteratorBody.concat([
						Else,
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null)
					]);
					// Dynamic iterators may walk storage of any element type; read it like Array<Dynamic>.
					var readAny = (switch (output.type) {
						case Dyn: true;
						default: false;
					}) ? functions.get("__array_get_any") : null;
					iteratorBody = iteratorBody.concat(readAny != null ? [
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						Call(readAny)
					] : [
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(stride),
						I32Mul,
						I32Add,
						load(output.type, 0)
					]);
					iteratorBody = iteratorBody.concat([
						LocalSet(outputLocal),
						LocalGet(iteratorLocal),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(1),
						I32Add,
						I32Store(positionOffset),
						Else
					]);
					iteratorBody = iteratorBody.concat(trapOrThrow(3));
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
			case Intrinsic(_, _, _):
				throw "Unlowered IR intrinsic reached Wasm";
			case Call(output, name, arguments):
				var gcRepresentation:Null<WasmGcRepresentation> = Std.isOfType(context.representation.values,
					WasmGcRepresentation) ? cast(context.representation.values, WasmGcRepresentation) : null;
				if (name == compiler.ir.IrReferenceIdentity.NAME) {
					for (argument in arguments) {
						body.push(LocalGet(requiredLocal(values, argument.id)));
						if (gcRepresentation != null)
							body.push(RefCast({nullable: true, heap: Eq}));
					}
					body.push(gcRepresentation == null ? I32Eq : RefEq);
					body.push(LocalSet(requiredLocal(values, output.id)));
					return;
				}
				if (name == compiler.ir.IrReceiverCheck.NAME) {
					var check:Array<WasmInstruction> = [
						LocalGet(requiredLocal(values, arguments[0].id)),
						gcRepresentation == null || (switch arguments[0].type {
							case EnumTag(_): true;
							default: false;
						}) ? I32Eqz : RefIsNull,
						If(null)
					];
					if (!knownNonNull)
						emit(body, check.concat(trapOrThrow(1)).concat([End]));
					return;
				}
				if (compiler.ir.IrScalarWordBits.matches(name)) {
					if (arguments.length != 1 || !compiler.ir.IrScalarWordBits.valid(name, arguments[0].type, output.type))
						throw "Invalid scalar word transport signature";
					body.push(LocalGet(requiredLocal(values, arguments[0].id)));
					if (!((switch output.type {
						case I32, EnumTag(_): true;
						default: false;
					}) && (switch arguments[0].type {
						case I32, EnumTag(_): true;
						default: false;
					})))
						body.push(name == compiler.ir.IrScalarWordBits.PACK ? I64ExtendI32U : I32WrapI64);
					body.push(LocalSet(requiredLocal(values, output.id)));
					return;
				}
				if (name == compiler.ir.IrValueLaneReference.PACK || name == compiler.ir.IrValueLaneReference.UNPACK) {
					body.push(LocalGet(requiredLocal(values, arguments[0].id)));
					if (gcRepresentation != null) {
						var carried = name == compiler.ir.IrValueLaneReference.PACK ? arguments[0].type : output.type;
						switch gcRepresentation.valueType(carried) {
							case Ref(reference):
								if (name == compiler.ir.IrValueLaneReference.UNPACK) switch reference.heap {
									case Any:
									default: body.push(RefCast(reference));
								}
							default: throw 'A scalar value cannot occupy a Wasm GC reference lane: $carried';
						}
					}
					body.push(LocalSet(requiredLocal(values, output.id)));
					return;
				}
				if (name == compiler.backend.wasm.WasmScalarAbi.RETURN_MARKER) {
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					return;
				}
				if (name == compiler.backend.wasm.WasmScalarAbi.RETHROW_MARKER) {
					body.push(LocalGet(requiredLocal(values, arguments[1].id)));
					body.push(If(null));
					if (context.runtimeNeutral && context.exceptionState != null)
						emitNeutralThrow(body, requiredLocal(values, arguments[0].id), context.exceptionDispatchIndex + 1);
					else if (context.exceptionTag == null)
						body.push(Unreachable);
					else {
						body.push(LocalGet(requiredLocal(values, arguments[0].id)));
						body.push(Throw(context.exceptionTag));
					}
					body.push(End);
					return;
				}
				if (gcRepresentation != null && gcRepresentation.hasScalarCall(name)) {
					var index = functions.get(name);
					if (index == null)
						throw 'Missing scalar Wasm GC function "$name"';
					emit(body, gcRepresentation.scalarCall(name, output, arguments, (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)], index));
					return;
				}
				var linearScalar:Null<compiler.backend.wasm.linear.WasmLinearRepresentation> = Std.isOfType(context.representation.values,
					compiler.backend.wasm.linear.WasmLinearRepresentation) ? cast context.representation.values : null;
				if (linearScalar != null && linearScalar.hasScalarCall(name)) {
					var index = functions.get(name);
					if (index == null)
						throw 'Missing scalar Wasm function "$name"';
					emit(body, linearScalar.scalarCall(name, output, arguments, (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)], index));
					return;
				}
				var host = WasmModuleSupport.hostCNative(context.program, name);
				if (host != null)
					lowerInstruction(body, CNativeCall(output, host.name, arguments), values, functions, layout, allocator, globals, strings, methods,
						closureTypes);
				else {
					var runtimeName = name;
					for (native in context.program.natives)
						if (native.name == name)
							runtimeName = native.symbol;
					if (runtimeName == "__value_iterator_new") {
						lowerInstruction(body, IteratorNew(output, arguments[0]), values, functions, layout, allocator, globals, strings, methods,
							closureTypes);
						return;
					}
					if (runtimeName == "__value_iterator_array" || runtimeName == "__value_iterator_advance") {
						var iterator = arguments[0],
							iteratorLocal = requiredLocal(values, iterator.id),
							destination = requiredLocal(values, output.id);
						if (Std.isOfType(context.representation.values, WasmGcRepresentation)) {
							var gc:WasmGcRepresentation = cast context.representation.values;
							emit(body,
								runtimeName == "__value_iterator_array" ? gc.valueIteratorArray(iterator, destination,
									iteratorLocal) : gc.valueIteratorAdvance(iterator, destination, iteratorLocal));
						} else if (runtimeName == "__value_iterator_array") {
							emit(body, [
								LocalGet(iteratorLocal),
								I32Load(WasmLayout.ITERATOR_ARRAY_OFFSET),
								LocalSet(destination)
							]);
						} else {
							var sequence:Array<WasmInstruction> = [
								LocalGet(iteratorLocal),
								I32Load(WasmLayout.ITERATOR_POSITION_OFFSET),
								LocalGet(iteratorLocal),
								I32Load(WasmLayout.ITERATOR_ARRAY_OFFSET),
								I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
								I32LtS,
								If(null),
								LocalGet(iteratorLocal),
								I32Load(WasmLayout.ITERATOR_POSITION_OFFSET),
								LocalSet(destination),
								LocalGet(iteratorLocal),
								LocalGet(destination),
								I32Const(1),
								I32Add,
								I32Store(WasmLayout.ITERATOR_POSITION_OFFSET),
								Else
							];
							sequence = sequence.concat(trapOrThrow(1));
							sequence.push(End);
							emit(body, sequence);
						}
						return;
					}
					var outputLocal = (switch (output.type) {
						case Void: true;
						default: false;
					}) ? -1 : requiredLocal(values,
						output.id), interop = context.representation.interop, represented = interop == null ? UseDefault : interop.lowerRuntimeCall(runtimeName,
							output, arguments, outputLocal, [for (argument in arguments) requiredLocal(values, argument.id)]);
					if (emitIfHandled(body, represented)) {} else {
						var gcRuntime:WasmLoweringResult = Std.isOfType(context.representation.values,
							WasmGcRepresentation) ? cast(context.representation.values, WasmGcRepresentation).lowerRuntimeCall(StringTools.startsWith(name,
								"$wasm:closure-receiver:") ? name : runtimeName, output, arguments, outputLocal,
								[for (argument in arguments) requiredLocal(values, argument.id)]) : UseDefault;
						if (!emitIfHandled(body, gcRuntime) && !lowerInt64Native(body, output, name, arguments, values)) {
							for (argument in arguments)
								body.push(LocalGet(requiredLocal(values, argument.id)));
							var functionIndex = functions.get(name);
							var mapParts = WasmModuleSupport.mapNativeParts(name);
							if (mapParts != null && (switch (output.type) {
								case Void: false;
								default: true;
							}) && (mapParts.operation == "keys" || mapParts.operation == "values")) {
								var projectionIndex = functions.get(WasmGcMaps.projectionName(name, output.type));
								if (projectionIndex != null)
									functionIndex = projectionIndex;
							}
							if (functionIndex == null)
								throw 'Wasm call to unsupported native or missing function "$name"';
							body.push(Call(functionIndex));
							if ((switch (output.type) {
								case Void: false;
								default: true;
							}))
								body.push(LocalSet(requiredLocal(values, output.id)));
						}
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
				if (((switch (native.result) {
					case ManagedBytes: true;
					default: false;
				}) && native.pointerLength != null) || (WasmModuleSupport.isGcNativePointerType(native.result)
					&& native.pointerOwnership == "owned")) {
					var lengthNative:Null<IrCNative> = null;
					if ((switch (native.result) {
						case ManagedBytes: true;
						default: false;
					}) && native.pointerLength != null) {
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
				var outputLocal = (switch (output.type) {
					case Void: true;
					default: false;
				}) ? -1 : requiredLocal(values,
					output.id), interop = context.representation.interop, represented = interop == null ? UseDefault : interop.lowerCNativeCall(native,
						arguments, outputLocal, [for (argument in arguments) requiredLocal(values, argument.id)], importIndex, pointerLengthImportIndex,
						pointerReleaseImportIndex);
				if (emitIfHandled(body, represented)) {} else {
					var bytesDataPointer = functions.get("__haxeon_bytes_data_pointer");
					if (bytesDataPointer == null)
						throw "Wasm byte data pointer helper is missing";
					for (argument in arguments)
						nativeArgument(body, argument, values, bytesDataPointer);
					body.push(Call(importIndex));
					if ((switch (output.type) {
						case Void: false;
						default: true;
					}))
						body.push(LocalSet(requiredLocal(values, output.id)));
				}
		}
	}

	static function lowerInt64Native(body:Array<WasmInstruction>, output:IrValue, name:String, arguments:Array<IrValue>, values:Map<Int, Int>):Bool {
		if (name == "haxe.Int64.ofInt") {
			if (arguments.length != 1 || (switch (arguments[0].type) {
				case I32: false;
				default: true;
			}) || (switch (output.type) {
				case I64: false;
				default: true;
			}))
				throw "Invalid haxe.Int64.ofInt Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64ExtendI32S);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.fromFloat") {
			if (arguments.length != 1 || (switch (arguments[0].type) {
				case F64: false;
				default: true;
			}) || (switch (output.type) {
				case I64: false;
				default: true;
			}))
				throw "Invalid haxe.Int64.fromFloat Wasm native signature";
			// HashLink's C cast is undefined outside the Int64 range; Wasm saturates instead of trapping.
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64TruncSatF64S);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.toInt") {
			if (arguments.length != 1 || (switch (output.type) {
				case I32: false;
				default: true;
			}))
				throw "Invalid haxe.Int64.toInt Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I32WrapI64);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.compare") {
			if (arguments.length != 2 || (switch (output.type) {
				case I32: false;
				default: true;
			}))
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
			if (arguments.length != 2 || (switch (output.type) {
				case I64: false;
				default: true;
			}))
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
		if (name == "haxe.Int64.neg") {
			if (arguments.length != 1 || (switch (output.type) {
				case I64: false;
				default: true;
			}))
				throw "Invalid haxe.Int64.neg Wasm native signature";
			body.push(I64Const(0));
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64Sub);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.make") {
			if (arguments.length != 2 || (switch (output.type) {
				case I64: false;
				default: true;
			}))
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
		if (arguments.length != 2 || (switch (output.type) {
			case I64: false;
			default: true;
		}))
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
			case Abstract("realtime_bytes"):
				body.push(Call(bytesDataPointer));
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

	/** Linear Dynamic representation of a value: primitives are boxed with their runtime type id. */
	function boxedValue(type:IrType, source:Int, destination:Int, allocator:Int):Array<WasmInstruction> {
		var size = switch type {
			case I32, Bool, RawPtr, TypeRef, Abstract("native_callback"): WasmLayout.DYN_I32_SIZE;
			case F64: WasmLayout.DYN_F64_SIZE;
			case I64: WasmLayout.DYN_I64_SIZE;
			default: return [LocalGet(source), LocalSet(destination)];
		};
		var box:Array<WasmInstruction> = [
			I32Const(size),
			Call(allocator),
			LocalTee(destination),
			I32Const(typeId(type)),
			I32Store(0),
			LocalGet(destination),
			LocalGet(source),
			store(type, WasmLayout.DYN_PAYLOAD_OFFSET)
		];
		return switch type {
			case RawPtr, TypeRef, Abstract("native_callback"): [LocalGet(source), I32Eqz, If(null), I32Const(0), LocalSet(destination), Else].concat(box)
					.concat([End]);
			default: box;
		};
	}

	static function isBoxedPrimitive(type:IrType):Bool
		return switch type {
			case I32, Bool, I64, F64, RawPtr, TypeRef, Abstract("native_callback"): true;
			default: false;
		};

	/**
	 * Convert a value between an interface signature and its implementation's: a generic
	 * interface erases type parameters to Dynamic while implementations keep primitives.
	 */
	function adaptInterfaceValue(sourceType:IrType, targetType:IrType, source:Int, allocator:Int, dispatchDepth:Int):Array<WasmInstruction> {
		if (compiler.ir.IrVerifier.sameType(sourceType, targetType))
			return [LocalGet(source)];
		if (isBoxedPrimitive(sourceType) && (switch (targetType) {
			case Dyn: true;
			default: false;
		})) {
			var boxed = context.placement.allocate(I32);
			return boxedValue(sourceType, source, boxed, allocator).concat([LocalGet(boxed)]);
		}
		if ((switch (sourceType) {
			case Dyn: true;
			default: false;
		}) && (switch (targetType) {
			case RawPtr | TypeRef | Abstract("native_callback"): true;
			default: false;
		})) {
			var pointer = context.placement.allocate(I32);
			return [
				LocalGet(source),
				I32Eqz,
				If(null),
				I32Const(0),
				LocalSet(pointer),
				Else,
				LocalGet(source),
				I32Const(1),
				I32And,
				If(null)
			].concat(trapOrThrow(dispatchDepth + 2))
				.concat([
					End,
					LocalGet(source),
					I32Load(0),
					I32Const(typeId(targetType)),
					I32Eq,
					I32Eqz,
					If(null)
				])
				.concat(trapOrThrow(dispatchDepth + 2))
				.concat([
					End,
					LocalGet(source),
					I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
					LocalSet(pointer),
					End,
					LocalGet(pointer)
				]);
		}
		if ((switch (sourceType) {
			case Dyn: true;
			default: false;
		}) && isBoxedPrimitive(targetType))
			return [LocalGet(source), load(targetType, WasmLayout.DYN_PAYLOAD_OFFSET)];
		return switch [sourceType, targetType] {
			case [I32, F64]: [LocalGet(source), F64ConvertI32S];
			case [F64, I32]: [LocalGet(source), I32TruncF64S];
			default: [LocalGet(source)];
		};
	}

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
		var index = IrProgramIndex.of(program);
		for (object in index.implementorsOf(interfaceName)) {
			var functionName = index.findMethod(object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction = index.func(functionName);
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
		var index = IrProgramIndex.of(program);
		for (object in index.subtypesOf(staticType)) {
			var functionName = index.findMethod(object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction = index.func(functionName);
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

	static function isObjectSubtype(program:IrProgram, actual:String, expected:String):Bool
		return IrProgramIndex.of(program).isObjectSubtype(actual, expected);

	static function objectInheritanceDepth(program:IrProgram, typeName:String):Int
		return IrProgramIndex.of(program).inheritanceDepth(typeName);

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String>
		return IrProgramIndex.of(program).findMethod(objectName, methodName);

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool
		return IrProgramIndex.of(program).implementsInterface(objectName, interfaceName);

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool
		return IrProgramIndex.of(program).interfaceExtends(actual, expected);

	function typeId(type:IrType):Int
		return context.module.runtimeTypeId(type);

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
		if ((switch (left.type) {
			case I64: true;
			default: false;
		}) && (switch (right.type) {
			case I32: true;
			default: false;
		}))
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

	static function emitIfHandled(body:Array<WasmInstruction>, result:WasmLoweringResult):Bool
		return switch result {
			case Handled(instructions):
				emit(body, instructions);
				true;
			case UseDefault: false;
		};

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), StaticDataAddress(output, _),
				ConstBool(output, _), PointerOffset(output, _, _), MemoryLoad(output, _, _, _), ConstNull(output), TypeValue(output, _), ToDyn(output, _),
				IntToFloat(output, _), IntToInt64(output, _), FloatToInt(output, _), FloatToFloat(output, _), SafeCast(output, _), Catch(output),
				GlobalGet(output, _), Intrinsic(output, _, _), Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _), Mod(output, _, _),
				BitAnd(output, _, _), BitXor(output, _, _), BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _),
				UnsignedShiftRight(output, _, _), Less(output, _, _), LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _),
				CNativeCall(output, _, _), StaticClosure(output, _), InstanceClosure(output, _, _), CallClosure(output, _, _), ToVirtual(output, _),
				Upcast(output, _), ClassId(output, _), MethodCall(output, _, _, _, _), NewObject(output, _), FieldGet(output, _, _), ArrayGet(output, _, _),
				ArraySize(output, _), IteratorNew(output, _), IteratorHasNext(output, _), IteratorNext(output, _), MakeEnum(output, _, _, _),
				EnumIndex(output, _), EnumField(output, _, _, _): output;
			case BeginTry(_, _, _), EndTry(_, _), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _), MemoryStore(_, _, _): null;
		};

	/** Converts a boxed Int, Float, Bool or Int64 at `value` to `target` (I32 or F64); null gives zero. */
	function dynamicNumber(target:IrType, value:Int, output:Int):Array<WasmInstruction> {
		var sources:Array<IrType> = (switch (target) {
			case F64: true;
			default: false;
		}) ? [F64, I32, Bool, I64] : [I32, F64, Bool, I64], instructions:Array<WasmInstruction> = [
			LocalGet(value),
			I32Eqz,
			If(null),
			(switch (target) {
				case F64: true;
				default: false;
			})
			? F64Const(0) : I32Const(0),
			LocalSet(output),
			Else
			];
		for (source in sources) {
			var convert:Array<WasmInstruction> = switch [source, target] {
				case [F64, F64] | [I32, I32] | [Bool, I32]: [];
				case [I32, F64] | [Bool, F64]: [F64ConvertI32S];
				case [I64, F64]: [F64ConvertI64S];
				case [F64, I32]: [I32TruncF64S];
				case [I64, I32]: [I32WrapI64];
				default: throw 'Unsupported dynamic number conversion from $source to $target';
			};
			instructions = instructions.concat([
				LocalGet(value),
				I32Load(0),
				I32Const(typeId(source)),
				I32Eq,
				If(null),
				LocalGet(value),
				load(source, WasmLayout.DYN_PAYLOAD_OFFSET)
			]);
			instructions = instructions.concat(convert);
			instructions = instructions.concat([LocalSet(output), Else]);
		}
		instructions.push(Unreachable);
		for (_ in sources)
			instructions.push(End);
		instructions.push(End);
		return instructions;
	}
}
