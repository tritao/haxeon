package compiler.backend.wasm;

import compiler.ir.Ir.IrCNative;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

typedef WasmFunctionRepresentationContext = {
	final allocateLocal:WasmValueType->Int;
	final exceptionTag:Null<Int>;
	final irFunction:Null<IrFunction>;
}

enum WasmLoweringKind {
	Handled(instructions:Array<WasmInstruction>);
	UseDefault;
}

abstract WasmLoweringResult(WasmLoweringKind) from WasmLoweringKind to WasmLoweringKind {
	@:from public static function fromInstructions(instructions:Array<WasmInstruction>):WasmLoweringResult
		return WasmLoweringKind.Handled(instructions);
}

/** Value typing and representation-sensitive value operations. */
interface WasmValueRepresentation {
	public function valueType(type:IrType):WasmValueType;
	public function zeroValue(type:IrType):Array<WasmInstruction>;
	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>;
	public function constantString(value:String, destination:Int, strings:Map<String, Int>):WasmLoweringResult;
	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult;
	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult;
	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult;
	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction>;
	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):WasmLoweringResult;
}

/** Heap aggregates, arrays, iterators, and enums. */
interface WasmAggregateRepresentation {
	public function newObject(typeName:String, destination:Int):Array<WasmInstruction>;
	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction>;
	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction>;
	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):WasmLoweringResult;
	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):WasmLoweringResult;
	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult;
	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult;
	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult;
	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult;
	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int, argumentLocals:Array<Int>):WasmLoweringResult;
	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult;
	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):WasmLoweringResult;
}

/** Closures and dynamic dispatch. */
interface WasmCallRepresentation {
	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}>, receiverLocal:Int, destination:Int,
		argumentLocals:Array<Int>):WasmLoweringResult;
	public function staticClosure(name:String, tableSlots:Map<String, Int>, destination:Int):WasmLoweringResult;
	public function instanceClosure(name:String, tableSlots:Map<String, Int>, receiverLocal:Int, destination:Int):WasmLoweringResult;
	public function callClosure(staticType:Int, instanceType:Null<Int>, arguments:Array<IrValue>, closureLocal:Int, destination:Int,
		argumentLocals:Array<Int>):WasmLoweringResult;
}

/** Runtime and C-native calls whose ABI depends on the reference model. */
interface WasmInteropRepresentation {
	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>):WasmLoweringResult;
	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
		pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):WasmLoweringResult;
}

/** Explicit capability set selected once per module and instantiated per function. */
class WasmRepresentationSet {
	public final values:WasmValueRepresentation;
	public final aggregates:WasmAggregateRepresentation;
	public final calls:Null<WasmCallRepresentation>;
	public final interop:Null<WasmInteropRepresentation>;

	final makeFunction:Null<WasmFunctionRepresentationContext->WasmRepresentationSet>;

	public function new(values:WasmValueRepresentation, aggregates:WasmAggregateRepresentation, calls:Null<WasmCallRepresentation>,
			interop:Null<WasmInteropRepresentation>, makeFunction:Null<WasmFunctionRepresentationContext->WasmRepresentationSet>) {
		this.values = values;
		this.aggregates = aggregates;
		this.calls = calls;
		this.interop = interop;
		this.makeFunction = makeFunction;
	}

	public function forFunction(context:WasmFunctionRepresentationContext):WasmRepresentationSet
		return makeFunction == null ? this : makeFunction(context);
}
