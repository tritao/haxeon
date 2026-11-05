package compiler.backend.wasm.linear;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneRuntime;
import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/** Physical storage primitives used by the portable lane policy on Wasm32. */
class WasmLinearLaneStorage {
	public static function register(context:WasmLinearContext):Void {
		var allocator = -1;
		for (native in context.program.natives) if (StringTools.startsWith(native.name, IrValueLaneRuntime.PRIMITIVE)) {
			if (allocator < 0) {
				var alloc:IrNative = {name:"$lane-storage:allocate", library:"haxeon_runtime", symbol:"__value_array_alloc",
					arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
				allocator = context.module.addFunction(WasmLinearValueArrays.allocate(context.module, alloc, context.allocatorFunction));
			}
			var operation = native.name.substr(IrValueLaneRuntime.PRIMITIVE.length), fn = switch operation {
				case "replace-capacity": WasmLinearValueArrays.replaceCapacity(native, context.allocatorFunction);
				case "new-like": WasmLinearValueArrays.newLike(allocator, native.name);
				default: build(native, operation);
			};
			var prefix:Array<WasmInstruction> = [];
			for (i in 0...native.arguments.length) switch native.arguments[i] {
				case Array(_): prefix = prefix.concat(WasmLinearValueArrays.resolveForward(i)).concat(requireArray(i));
				default:
			}
			for (i in 0...prefix.length) fn.body.insert(i, prefix[i]);
			context.functions.set(native.name, context.module.addFunction(fn));
		}
	}

	static function requireArray(index:Int):Array<WasmInstruction> {
		var b = new WasmFunctionBuilder("require-lane", {parameters:[],results:[]});
		b.emitAll([LocalGet(index), I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b);
		b.emitAll([End, LocalGet(index), I32Load(WasmLayout.VALUE_ARRAY_MARKER_OFFSET), I32Const(WasmLayout.VALUE_ARRAY_MARKER), I32Eq, I32Eqz, If(null)]); WasmLinearRuntime.runtimeFailure(b); b.emit(End);
		return b.body;
	}

	static function build(native:IrNative, operation:String):WasmFunction {
		var b = new WasmFunctionBuilder(native.name, {parameters:[for (a in native.arguments) WasmModuleSupport.requireValueType(a)],
			results:WasmModuleSupport.resultTypes(native.result)});
		switch operation {
			case "length", "capacity", "has-validity":
				b.emitAll([LocalGet(0), I32Load(operation == "length" ? WasmLayout.ARRAY_LENGTH_OFFSET : operation == "capacity" ?
					WasmLayout.ARRAY_CAPACITY_OFFSET : WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET)]);
			case "publish-length":
				b.emitAll([LocalGet(0), LocalGet(1), I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)]);
				b.emitAll(WasmLinearValueArrays.syncForwardLength());
			case "compatible":
				b.emit(I32Const(1));
				for (offset in [WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET, WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET,
					WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET, WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET])
					b.emitAll([LocalGet(0), I32Load(offset), LocalGet(1), I32Load(offset), I32Eq, I32And]);
			case "fail": WasmLinearRuntime.runtimeFailure(b);
			case "clear-scalars", "clear-references", "copy-scalars", "copy-references":
				var scalar = StringTools.endsWith(operation, "scalars"), copy = StringTools.startsWith(operation, "copy"),
					data = scalar ? WasmLayout.ARRAY_DATA_POINTER_OFFSET : WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET,
					stride = b.local("stride-bytes", I32);
				b.emitAll([LocalGet(0), I32Load(scalar ? WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET : WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET),
					I32Const(scalar ? 8 : 4), scalar ? I32DivS : I32Mul, LocalSet(stride),
					LocalGet(0), I32Load(data), LocalGet(1), LocalGet(stride), I32Mul, I32Add]);
				if (copy) b.emitAll([LocalGet(2), I32Load(data), LocalGet(3), LocalGet(stride), I32Mul, I32Add]);
				else b.emit(I32Const(0));
				b.emitAll([LocalGet(copy ? 4 : 2), LocalGet(stride), I32Mul, copy ? MemoryCopy : MemoryFill]);
			case "read-validity":
				b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(I32)]);
				WasmLinearValueArrays.appendValidityAddress(b);
				b.emitAll([I32Load8U(0), LocalGet(1), I32Const(7), I32And, I32ShrU, I32Const(1), I32And, Else, I32Const(1), End]);
			case "write-validity":
				var address = b.local("address", I32), mask = b.local("mask", I32);
				b.emitAll([LocalGet(0), I32Load(WasmLayout.VALUE_ARRAY_VALIDITY_OFFSET), If(null)]);
				WasmLinearValueArrays.appendValidityAddress(b); b.emit(LocalSet(address));
				b.emitAll([I32Const(1), LocalGet(1), I32Const(7), I32And, I32Shl, LocalSet(mask), LocalGet(address),
					LocalGet(address), I32Load8U(0), LocalGet(mask), I32Const(-1), I32Xor, I32And,
					LocalGet(2), If(I32), LocalGet(mask), Else, I32Const(0), End, I32Or, I32Store8(0), End]);
			case "swap-scalars", "swap-references":
				var scalar = operation == "swap-scalars", data = scalar ? WasmLayout.ARRAY_DATA_POINTER_OFFSET : WasmLayout.VALUE_ARRAY_REFERENCE_DATA_OFFSET,
					stride = b.local("stride", I32), cursor = b.local("cursor", I32), left = b.local("left", I32),
					right = b.local("right", I32), temp = b.local("temporary", I32);
				b.emitAll([LocalGet(0), I32Load(scalar ? WasmLayout.VALUE_ARRAY_SCALAR_STRIDE_OFFSET : WasmLayout.VALUE_ARRAY_REFERENCE_STRIDE_OFFSET),
					I32Const(scalar ? 8 : 4), scalar ? I32DivS : I32Mul, LocalSet(stride),
					LocalGet(0), I32Load(data), LocalGet(1), LocalGet(stride), I32Mul, I32Add, LocalSet(left),
					LocalGet(0), I32Load(data), LocalGet(2), LocalGet(stride), I32Mul, I32Add, LocalSet(right),
					Block(null), Loop(null), LocalGet(cursor), LocalGet(stride), I32Eq, BrIf(1),
					LocalGet(left), LocalGet(cursor), I32Add, scalar ? I32Load8U(0) : I32Load(0), LocalSet(temp),
					LocalGet(left), LocalGet(cursor), I32Add, LocalGet(right), LocalGet(cursor), I32Add,
					scalar ? I32Load8U(0) : I32Load(0), scalar ? I32Store8(0) : I32Store(0),
					LocalGet(right), LocalGet(cursor), I32Add, LocalGet(temp), scalar ? I32Store8(0) : I32Store(0),
					LocalGet(cursor), I32Const(scalar ? 1 : 4), I32Add, LocalSet(cursor), Br(0), End, End]);
			default: throw 'Unknown Wasm32 lane storage primitive: $operation';
		}
		b.emit(Return); return b.finish();
	}
}
