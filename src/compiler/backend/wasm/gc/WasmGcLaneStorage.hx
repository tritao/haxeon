package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneRuntime;
import compiler.backend.wasm.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** GC storage operations underneath the shared structural lane policy. */
class WasmGcLaneStorage {
	public static function register(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, program:IrProgram):Void {
		var primitives = [for (n in program.natives) if (StringTools.startsWith(n.name, IrValueLaneRuntime.PRIMITIVE)) n];
		if (primitives.length == 0) return;
		var throws = WasmModuleSupport.hasExceptions(program),
			read = WasmGcScalarRange.byteHelpers(module, plan, false), write = WasmGcScalarRange.byteHelpers(module, plan, true),
			alloc:IrNative = {name:"$lane-storage-internal:allocate", library:"haxeon_runtime", symbol:"__value_array_alloc",
				arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)},
			allocator = module.addFunction(WasmGcValueArrays.allocate(plan, alloc, throws));
		for (native in primitives) {
			var operation = native.name.substr(IrValueLaneRuntime.PRIMITIVE.length), fn = switch operation {
				case "replace-capacity": WasmGcValueArrays.replaceCapacity(plan, native, throws);
				case "new-like": WasmGcValueArrays.newLike(plan, allocator, native.name);
				default: build(plan, native, operation, throws, read, write);
			};
			var prefix:Array<WasmInstruction> = [];
			for (i in 0...native.arguments.length) switch native.arguments[i] {
				case Array(_):
					prefix = prefix.concat(WasmGcValueArrays.resolveForward(plan, i)).concat([
						LocalGet(i), RefTest({nullable:false, heap:Type(plan.valueArrayWrapperTypeIndex)}), I32Eqz, If(null)])
						.concat(WasmGcValueArrays.failure(throws)).concat([End]);
				default:
			}
			for (i in 0...prefix.length) fn.body.insert(i, prefix[i]);
			functions.set(native.name, module.addFunction(fn));
		}
	}

	static function field(b:WasmFunctionBuilder, plan:WasmGcTypePlan, index:Int, array:Int = 0):Void
		b.emitAll([LocalGet(array), RefCast({nullable:false,heap:Type(plan.valueArrayWrapperTypeIndex)}), StructGet(plan.valueArrayWrapperTypeIndex,index)]);
	static function setField(b:WasmFunctionBuilder, plan:WasmGcTypePlan, index:Int, value:Int):Void {
		b.emitAll([LocalGet(0), RefCast({nullable:false,heap:Type(plan.valueArrayWrapperTypeIndex)}), LocalGet(value), StructSet(plan.valueArrayWrapperTypeIndex,index)]);
	}


	static function build(plan:WasmGcTypePlan, native:IrNative, operation:String, throws:Bool, read:Array<Int>, write:Array<Int>):WasmFunction {
		var b = new WasmFunctionBuilder(native.name, plan.wasmFunctionType(native.arguments,native.result));
		switch operation {
			case "length", "capacity", "has-validity":
				field(b, plan, operation == "length" ? WasmGcTypePlan.arrayLengthFieldIndex() : operation == "capacity" ?
					WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD : WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD);
			case "publish-length": setField(b, plan, WasmGcTypePlan.arrayLengthFieldIndex(),1); b.emitAll(WasmGcValueArrays.syncForwardLength(plan));
			case "fail": b.emitAll(WasmGcValueArrays.failure(throws));
			case "compatible":
				b.emit(I32Const(1));
				for (index in [WasmGcTypePlan.arrayElementTypeFieldIndex(),WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD,
					WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD,WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD,WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD]) {
					field(b,plan,index); field(b,plan,index,1); b.emitAll([I32Eq,I32And]);
				}
			case "read-validity": b.emitAll(WasmGcValueArrays.initialized(plan));
			case "write-validity": bitmapWrite(b,plan);
			case "clear-scalars", "copy-scalars", "swap-scalars": WasmGcScalarRange.emit(b,plan,operation,read,write);
			case "clear-references", "copy-references", "swap-references": referenceRange(b,plan,operation);
			default: throw 'Unknown GC lane storage operation $operation';
		}
		b.emit(Return); return b.finish();
	}

	static function bitmapWrite(b:WasmFunctionBuilder, plan:WasmGcTypePlan):Void {
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD); b.emit(If(null));
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD); b.emitAll([I32Const(32),I32Eq,If(null)]);
		for (lane in [plan.valueArrayI32LaneTypeIndex,plan.valueArrayI64LaneTypeIndex]) {
			var small = lane == plan.valueArrayI32LaneTypeIndex;
			field(b,plan,WasmGcTypePlan.arrayDataFieldIndex()); b.emit(RefCast({nullable:false,heap:Type(lane)}));
			b.emitAll(WasmGcValueArrays.bitmapWordIndex(plan.valueArrayWrapperTypeIndex));
			field(b,plan,WasmGcTypePlan.arrayDataFieldIndex()); b.emit(RefCast({nullable:false,heap:Type(lane)}));
			b.emitAll(WasmGcValueArrays.bitmapWordIndex(plan.valueArrayWrapperTypeIndex)); b.emit(ArrayGet(lane));
			if (small) b.emit(I64ExtendI32U);
			b.emit(I64Const(1)); b.emitAll(WasmGcValueArrays.bitmapBit(plan.valueArrayWrapperTypeIndex));
			b.emitAll([I64Shl,I64Const(-1),I64Xor,I64And,LocalGet(2),If(I64),I64Const(1)]);
			b.emitAll(WasmGcValueArrays.bitmapBit(plan.valueArrayWrapperTypeIndex)); b.emitAll([I64Shl,Else,I64Const(0),End,I64Or]);
			if (small) b.emit(I32WrapI64);
			b.emit(ArraySet(lane)); if (small) b.emit(Else);
		}
		b.emitAll([End,End]);
	}


	/** Select the eager sole reference lane or the lazy mixed lane without allocating. */
	static function references(b:WasmFunctionBuilder, plan:WasmGcTypePlan, array:Int, output:Int):Void {
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD,array); b.emit(I32Eqz);
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD,array); b.emitAll([I32Eqz,I32And,If(null)]);
		field(b,plan,WasmGcTypePlan.arrayDataFieldIndex(),array); b.emitAll([RefCast({nullable:false,heap:Type(plan.valueArrayReferenceLaneTypeIndex)}),LocalSet(output),Else]);
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD,array); b.emitAll([RefCast({nullable:true,heap:Type(plan.valueArrayReferenceLaneTypeIndex)}),LocalSet(output),End]);
	}

	static function referenceRange(b:WasmFunctionBuilder, plan:WasmGcTypePlan, operation:String):Void {
		var copy = operation == "copy-references", swap = operation == "swap-references", lane = plan.valueArrayReferenceLaneTypeIndex,
			laneType:WasmValueType = Ref({nullable:true,heap:Type(lane)}), to = b.local("target-lane",laneType), from = b.local("source-lane",laneType),
			stride = b.local("reference-stride",I32), start = b.local("target-start",I32), source = b.local("source-start",I32),
			count = b.local("count",I32), cursor = b.local("cursor",I32), temp = b.local("temporary",Ref({nullable:true,heap:Any}));
		field(b,plan,WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD); b.emitAll([LocalTee(stride),I32Eqz,If(null),Return,End,
			LocalGet(1),LocalGet(stride),I32Mul,LocalSet(start),swap ? I32Const(1) : LocalGet(copy ? 4 : 2),LocalGet(stride),I32Mul,LocalSet(count),
			LocalGet(count),I32Eqz,If(null),Return,End]);
		references(b,plan,0,to);
		if (copy || swap) {
			b.emitAll([LocalGet(copy ? 3 : 2),LocalGet(stride),I32Mul,LocalSet(source)]);
			if (copy) references(b,plan,2,from); else b.emitAll([LocalGet(to),LocalSet(from)]);
		}
		if (copy) {
			// A null-only copied range must not create the destination's lazy lane.
			b.emitAll([LocalGet(from),RefIsNull,I32Eqz,If(null),LocalGet(to),RefIsNull,If(null),Block(null),Loop(null),
				LocalGet(cursor),LocalGet(count),I32Eq,If(null),Return,End,
				LocalGet(from),RefCast({nullable:false,heap:Type(lane)}),LocalGet(source),LocalGet(cursor),I32Add,ArrayGet(lane),RefIsNull,I32Eqz,BrIf(1),
				LocalGet(cursor),I32Const(1),I32Add,LocalSet(cursor),Br(0),End,End]);
			field(b,plan,WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD); b.emitAll([LocalGet(stride),I32Mul,ArrayNewDefault(lane),LocalSet(to)]);
			setField(b,plan,WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD,to);
			b.emitAll([End,LocalGet(to),RefCast({nullable:false,heap:Type(lane)}),LocalGet(start),
				LocalGet(from),RefCast({nullable:false,heap:Type(lane)}),LocalGet(source),LocalGet(count),ArrayCopy(lane,lane),Return,End]);
		}
		b.emitAll([LocalGet(to),RefIsNull,If(null),Return,End,I32Const(0),LocalSet(cursor),Block(null),Loop(null),LocalGet(cursor),LocalGet(count),I32Eq,BrIf(1)]);
		if (swap) b.emitAll([LocalGet(to),RefCast({nullable:false,heap:Type(lane)}),LocalGet(start),LocalGet(cursor),I32Add,ArrayGet(lane),LocalSet(temp)]);
		b.emitAll([LocalGet(to),RefCast({nullable:false,heap:Type(lane)}),LocalGet(start),LocalGet(cursor),I32Add]);
		if (swap) b.emitAll([LocalGet(from),RefCast({nullable:false,heap:Type(lane)}),LocalGet(source),LocalGet(cursor),I32Add,ArrayGet(lane)]);
		else b.emit(RefNull(Any));
		b.emit(ArraySet(lane));
		if (swap) b.emitAll([LocalGet(to),RefCast({nullable:false,heap:Type(lane)}),LocalGet(source),LocalGet(cursor),I32Add,LocalGet(temp),ArraySet(lane)]);
		b.emitAll([LocalGet(cursor),I32Const(1),I32Add,LocalSet(cursor),Br(0),End,End]);
	}
}
