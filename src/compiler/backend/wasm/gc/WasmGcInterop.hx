package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmGcTypePlan;
import compiler.backend.wasm.WasmRepresentation.WasmInteropRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

/** HXI and C-native ABI conversion for native Wasm GC values. */
class WasmGcInterop implements WasmInteropRepresentation {
	final gc:WasmGcContext;
	final plan:WasmGcTypePlan;
	final functionContext:Null<WasmGcFunctionContext>;
	final moduleInterop:WasmGcInterop;

	final scratchTop:Int;
	final scratchAllocator:Int;
	final nativePointerReleaseIndices:Array<Int>;
	final nativePointerReleaseBySymbol:Map<String, Int>;

	public function new(gc:WasmGcContext, scratchTop:Int, scratchAllocator:Int, pointerReleases:Map<String, Int>,
			?functionContext:WasmGcFunctionContext, ?moduleInterop:WasmGcInterop) {
		this.gc = gc;
		this.plan = gc.plan;
		this.functionContext = functionContext;
		this.moduleInterop = moduleInterop == null ? this : moduleInterop;
		if (moduleInterop == null) {
			this.scratchTop = scratchTop;
			this.scratchAllocator = scratchAllocator;
			this.nativePointerReleaseBySymbol = pointerReleases.copy();
			this.nativePointerReleaseIndices = [for (symbol in pointerReleases.keys()) pointerReleases.get(symbol)];
			this.nativePointerReleaseIndices.sort((left, right) -> left - right);
		} else {
			this.scratchTop = -1;
			this.scratchAllocator = -1;
			this.nativePointerReleaseBySymbol = [];
			this.nativePointerReleaseIndices = [];
		}
	}

	public function forFunctionContext(context:WasmGcFunctionContext):WasmGcInterop
		return new WasmGcInterop(gc, -1, -1, [], context, moduleInterop);

	function allocateLocal(type:WasmValueType):Int
		return functionState().allocateLocal(type);

	function functionState():WasmGcFunctionContext {
		if (functionContext == null)
			throw "Wasm GC interop operation requires a function context";
		return functionContext;
	}

	static function isNativePointerType(type:IrType):Bool
		return switch type {
			case Abstract("native_pointer"): true;
			case _: false;
		};

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):WasmLoweringResult {
		if (name == "structGetPointer") {
			if (!isNativePointerType(output.type) || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32
				|| arguments[2].type != Bool || argumentLocals.length != 3)
				throw "Invalid Wasm GC HXI pointer-field getter signature";
			var pointer = allocateLocal(I32),
				body = managedByteGetI32(argumentLocals[0], argumentLocals[1], pointer);
			return body.concat(wrapNativePointer(pointer, -1, argumentLocals[2], true, outputLocal));
		}
		if (name == "native_pointer_is_closed") {
			if (output.type != Bool || arguments.length != 1 || !isNativePointerType(arguments[0].type) || argumentLocals.length != 1)
				throw "Invalid Wasm GC native pointer status signature";
			var pointer = argumentLocals[0];
			return [LocalGet(pointer), RefIsNull, If(I32), I32Const(1), Else, LocalGet(pointer), StructGet(plan.nativePointerTypeIndex, 2), End,
				LocalSet(outputLocal)];
		}
		if (name == "native_pointer_close") {
			if (output.type != Bool || arguments.length != 1 || !isNativePointerType(arguments[0].type) || argumentLocals.length != 1)
				throw "Invalid Wasm GC native pointer close signature";
			var pointer = argumentLocals[0],
				releaseFunction = allocateLocal(I32),
				body:Array<WasmInstruction> = [I32Const(0), LocalSet(outputLocal), LocalGet(pointer), RefIsNull, If(null)];
			body.push(Else);
			body = body.concat([LocalGet(pointer), StructGet(plan.nativePointerTypeIndex, 2), I32Eqz, If(null)]);
			body = body.concat([LocalGet(pointer), StructGet(plan.nativePointerTypeIndex, 1), LocalSet(releaseFunction)]);
			for (index in moduleInterop.nativePointerReleaseIndices) {
				body = body.concat([LocalGet(releaseFunction), I32Const(index), I32Eq, If(null), LocalGet(pointer),
					StructGet(plan.nativePointerTypeIndex, 0), Call(index), LocalGet(pointer), I32Const(0), StructSet(plan.nativePointerTypeIndex, 0),
					LocalGet(pointer), I32Const(1), StructSet(plan.nativePointerTypeIndex, 2), I32Const(1), LocalSet(outputLocal), End]);
			}
			body = body.concat([End, End]);
			return body;
		}
		if (name == "native_pointer_owned_from_slot") {
			if (!isNativePointerType(output.type) || arguments.length != 7 || arguments[0].type != ManagedBytes || arguments[1].type != I32
				|| arguments[5].type != Bytes || arguments[6].type != Bool || argumentLocals.length != 7)
				throw "Invalid Wasm GC owned pointer slot helper signature";
			var releaseSymbol = functionState().functionStringConstants.get(arguments[5].id);
			if (releaseSymbol == null)
				throw "Wasm GC owned pointer slot release symbol must be a literal";
			var releaseFunction = moduleInterop.nativePointerReleaseBySymbol.get(releaseSymbol);
			if (releaseFunction == null)
				throw 'Wasm GC owned pointer slot has no imported release function "' + releaseSymbol + '"';
			var pointer = allocateLocal(I32),
				body = managedByteGetI32(argumentLocals[0], argumentLocals[1], pointer);
			return body.concat(wrapNativePointer(pointer, releaseFunction, argumentLocals[6], true, outputLocal));
		}
		if (name == "structWithRoots") {
			if (output.type != ManagedBytes || arguments.length != 2 || arguments[0].type != ManagedBytes
				|| !Type.enumEq(arguments[1].type, Array(ManagedBytes)) || argumentLocals.length != 2)
				throw "Invalid Wasm GC HXI structure root attachment signature";
			return [LocalGet(argumentLocals[0]), LocalGet(argumentLocals[1]), StructSet(plan.managedBytesTypeIndex, 3), LocalGet(argumentLocals[0]), LocalSet(outputLocal)];
		}
		if (name == "structGetRoots") {
			if (!Type.enumEq(output.type, Array(ManagedBytes)) || arguments.length != 1 || arguments[0].type != ManagedBytes || argumentLocals.length != 1)
				throw "Invalid Wasm GC HXI structure root query signature";
			return [LocalGet(argumentLocals[0]), StructGet(plan.managedBytesTypeIndex, 3), RefCast({nullable: false, heap: Type(plan.arrayType(ManagedBytes))}), LocalSet(outputLocal)];
		}
		return UseDefault;
	}

	function nativePointerRaw(pointerLocal:Int):Array<WasmInstruction>
		return [
			LocalGet(pointerLocal),
			RefIsNull,
			If(I32),
			I32Const(0),
			Else,
			LocalGet(pointerLocal),
			StructGet(plan.nativePointerTypeIndex, 0),
			End
		];

	function wrapNativePointer(rawLocal:Int, releaseFunction:Int, nullableLocal:Null<Int>, nullable:Bool, destination:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(rawLocal), I32Eqz, If(null)];
		if (nullableLocal != null)
			body = body.concat([LocalGet(nullableLocal), I32Eqz, If(null), Unreachable, End]);
		else if (!nullable)
			body.push(Unreachable);
		body = body.concat([
			RefNull(Type(plan.nativePointerTypeIndex)),
			LocalSet(destination),
			Else,
			LocalGet(rawLocal),
			I32Const(releaseFunction),
			I32Const(0),
			StructNew(plan.nativePointerTypeIndex),
			LocalSet(destination),
			End
		]);
		return body;
	}

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):WasmLoweringResult {
		var usesScratchBridge = false;
		for (mode in native.argumentModes)
			switch mode {
				case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize | Output | InputOutput | FixedInput(_, _, _) | FixedValue(_, _, _) |
					FixedOutput(_, _, _) | FixedInputOutput(_, _, _):
					usesScratchBridge = true;
				case Value:
			}
		if (usesScratchBridge && (moduleInterop.scratchAllocator < 0 || moduleInterop.scratchTop < 0))
			throw 'Wasm GC C native "${native.name}" requires a configured linear scratch bridge';
		var bytePointerResult = native.result == ManagedBytes && native.pointerLength != null;
		if (bytePointerResult && pointerLengthImportIndex < 0)
			throw 'Wasm GC C native "${native.name}" has no imported byte-result length function';
		if (bytePointerResult && native.pointerOwnership == "owned" && pointerReleaseImportIndex < 0)
			throw 'Wasm GC C native "${native.name}" has no imported byte-result release function';
		var fixedAggregateResult = native.fixedResult != null;
		var body:Array<WasmInstruction> = [],
			savedTop = usesScratchBridge ? allocateLocal(I32) : -1,
			bytePointers:Array<Null<Int>> = [];
		if (usesScratchBridge)
			body = body.concat([GlobalGet(moduleInterop.scratchTop), LocalSet(savedTop)]);
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInput(_) | BytesInputOutput(_):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte input $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(8),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case FixedInput(size, alignment, pointerFree) | FixedValue(size, alignment, pointerFree):
					if (arguments[index].type != ManagedBytes || !pointerFree)
						throw 'Wasm GC C native "${native.name}" fixed input $index must be a pointer-free managed aggregate';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(size),
						I32Eq,
						I32Eqz,
						If(null),
						Unreachable,
						End,
						I32Const(size),
						I32Const(alignment),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case Output | InputOutput:
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" scalar output pointer $index must use managed bytes';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(8),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					// HXI zeroes @out buffers and seeds @inout buffers before this call.
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case FixedOutput(size, alignment, pointerFree) | FixedInputOutput(size, alignment, pointerFree):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" aggregate output $index must use managed bytes';
					if (!pointerFree)
						throw 'Wasm GC C native "${native.name}" fixed output $index contains pointer fields, which Wasm GC FFI does not bridge yet';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(size),
						I32Eq,
						I32Eqz,
						If(null),
						Unreachable,
						End,
						I32Const(size),
						I32Const(alignment),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					// HXI constructs zeroed @out aggregates and supplies the current @inout layout.
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case BytesOutput(sizeArgument):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte output $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						sizeLocal = argumentLocals[sizeArgument],
						sizeOffset = allocateLocal(I32),
						capacity = allocateLocal(I32),
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						RefIsNull,
						If(null),
						I32Const(0),
						LocalSet(pointer),
						Else,
						I32Const(0),
						LocalSet(sizeOffset)
					]);
					body = body.concat(requireGcBytesLength(sizeLocal, 4));
					body = body.concat(managedByteGetI32(sizeLocal, sizeOffset, capacity));
					body = body.concat([
						LocalGet(capacity),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Eq,
						I32Eqz,
						If(null),
						Unreachable,
						End,
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(8),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
					body.push(End);
				case BytesSize:
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte size $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat(requireGcBytesLength(bytesLocal, 4));
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Const(8),
						Call(moduleInterop.scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case Value:
					if (isNativePointerType(arguments[index].type)) {
						var pointer = allocateLocal(I32);
						bytePointers[index] = pointer;
						body = body.concat(nativePointerRaw(argumentLocals[index]));
						body.push(LocalSet(pointer));
					} else
						bytePointers[index] = null;
				case _:
					throw 'Wasm GC C native "${native.name}" has an unsupported argument direction';
			}
		for (index in 0...arguments.length) {
			var pointer = bytePointers[index];
			body.push(LocalGet(pointer == null ? argumentLocals[index] : pointer));
		}
		var nativePointerResult = isNativePointerType(native.result),
			resultLocal = native.result == Void ? -1 : allocateLocal(bytePointerResult
				|| fixedAggregateResult
			|| nativePointerResult ? I32 : plan.valueType(native.result));
		body.push(Call(importIndex));
		if (resultLocal >= 0)
			body.push(LocalSet(resultLocal));
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInputOutput(_) | BytesSize:
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" byte argument $index has no scratch pointer';
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
				case Output | InputOutput:
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" scalar output pointer $index has no scratch pointer';
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
				case FixedOutput(_, _, _) | FixedInputOutput(_, _, _):
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" aggregate argument $index has no scratch pointer';
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
				case BytesOutput(_):
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" byte output $index has no scratch pointer';
					body = body.concat([LocalGet(argumentLocals[index]), RefIsNull, If(null), Else]);
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
					body.push(End);
				case _:
			}
		if (usesScratchBridge)
			body = body.concat([LocalGet(savedTop), GlobalSet(moduleInterop.scratchTop)]);
		if (bytePointerResult)
			body = body.concat(copyNativeBytesResult(native, argumentLocals, resultLocal, outputLocal, pointerLengthImportIndex, pointerReleaseImportIndex));
		else if (fixedAggregateResult)
			body = body.concat(copyNativeFixedResult(native, resultLocal, outputLocal));
		else if (nativePointerResult)
			body = body.concat(wrapNativePointer(resultLocal, native.pointerOwnership == "owned" ? pointerReleaseImportIndex : -1, null,
				native.pointerNullable, outputLocal));
		else if (resultLocal >= 0)
			body = body.concat([LocalGet(resultLocal), LocalSet(outputLocal)]);
		return body;
	}

	function copyNativeFixedResult(native:IrCNative, pointer:Int, outputLocal:Int):Array<WasmInstruction> {
		var layout = native.fixedResult;
		if (layout == null)
			throw 'Wasm GC C native "${native.name}" has no fixed result layout';
		var storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			position = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(pointer),
				I32Eqz,
				If(null),
				Unreachable,
				End,
				LocalGet(pointer),
				I32Const(layout.alignment - 1),
				I32And,
				I32Eqz,
				I32Eqz,
				If(null),
				Unreachable,
				End,
				I32Const(layout.size),
				ArrayNewDefault(plan.byteArrayTypeIndex),
				LocalSet(storage),
				I32Const(0),
				LocalSet(position),
				Block(null),
				Loop(null),
				LocalGet(position),
				I32Const(layout.size),
				I32LtS,
				I32Eqz,
				BrIf(1),
				LocalGet(storage),
				LocalGet(position),
				LocalGet(pointer),
				LocalGet(position),
				I32Add,
				I32Load8U(0),
				ArraySet(plan.byteArrayTypeIndex),
				LocalGet(position),
				I32Const(1),
				I32Add,
				LocalSet(position),
				Br(0),
				End,
				End,
				LocalGet(storage),
				I32Const(0),
				I32Const(layout.size),
				RefNull(Any),
				StructNew(plan.managedBytesTypeIndex),
				LocalSet(outputLocal)
			];
		return body;
	}

	function copyNativeBytesResult(native:IrCNative, argumentLocals:Array<Int>, pointer:Int, outputLocal:Int, lengthImportIndex:Int,
			releaseImportIndex:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			position = allocateLocal(I32),
			body:Array<WasmInstruction> = [LocalGet(pointer), I32Eqz, If(null)];
		if (native.pointerNullable)
			body = body.concat([RefNull(Type(plan.managedBytesTypeIndex)), LocalSet(outputLocal)]);
		else
			body.push(Unreachable);
		body.push(Else);
		for (argumentLocal in argumentLocals)
			body.push(LocalGet(argumentLocal));
		body = body.concat([
			Call(lengthImportIndex),
			LocalSet(length),
			LocalGet(length),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			End,
			LocalGet(length),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(storage),
			I32Const(0),
			LocalSet(position),
			Block(null),
			Loop(null),
			LocalGet(position),
			LocalGet(length),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(storage),
			LocalGet(position),
			LocalGet(pointer),
			LocalGet(position),
			I32Add,
			I32Load8U(0),
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(position),
			I32Const(1),
			I32Add,
			LocalSet(position),
			Br(0),
			End,
			End,
			LocalGet(storage),
			I32Const(0),
			LocalGet(length),
			RefNull(Any),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(outputLocal)
		]);
		if (native.pointerOwnership == "owned")
			body = body.concat([LocalGet(pointer), Call(releaseImportIndex)]);
		body.push(End);
		return body;
	}

	function copyGcBytesToLinear(bytesLocal:Int, pointer:Int):Array<WasmInstruction> {
		var position = allocateLocal(I32);
		return [
			I32Const(0),
			LocalSet(position),
			Block(null),
			Loop(null),
			LocalGet(position),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 2),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(pointer),
			LocalGet(position),
			I32Add,
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(position),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			I32Store8(0),
			LocalGet(position),
			I32Const(1),
			I32Add,
			LocalSet(position),
			Br(0),
			End,
			End
		];
	}

	function copyLinearToGcBytes(bytesLocal:Int, pointer:Int):Array<WasmInstruction> {
		var position = allocateLocal(I32);
		return [
			I32Const(0),
			LocalSet(position),
			Block(null),
			Loop(null),
			LocalGet(position),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 2),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(position),
			I32Add,
			LocalGet(pointer),
			LocalGet(position),
			I32Add,
			I32Load8U(0),
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(position),
			I32Const(1),
			I32Add,
			LocalSet(position),
			Br(0),
			End,
			End
		];
	}

	function requireGcBytesLength(bytesLocal:Int, minimum:Int):Array<WasmInstruction>
		return [
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 2),
			I32Const(minimum),
			I32LtS,
			If(null),
			Unreachable,
			End
		];

	function managedByteGetI32(bytesLocal:Int, indexLocal:Int, destination:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = checkedByteIndex(plan.managedBytesTypeIndex, bytesLocal, indexLocal, 4);
		for (byteIndex in 0...4) {
			body = body.concat([
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(indexLocal),
				I32Add,
				I32Const(byteIndex),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex)
			]);
			if (byteIndex > 0)
				body = body.concat([I32Const(byteIndex * 8), I32Shl]);
			if (byteIndex > 0)
				body.push(I32Or);
		}
		body.push(LocalSet(destination));
		return body;
	}

	function checkedByteIndex(wrapperType:Int, bytesLocal:Int, indexLocal:Int, width:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(indexLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			I32Const(width),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			I32Const(width),
			I32Sub,
			LocalGet(indexLocal),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body.push(End);
		return body;
	}

	function trapInstructions():Array<WasmInstruction> {
		var exceptionTag = functionState().exceptionTag;
		return exceptionTag == null ? [Unreachable] : [RefNull(Any), Throw(exceptionTag)];
	}

}
