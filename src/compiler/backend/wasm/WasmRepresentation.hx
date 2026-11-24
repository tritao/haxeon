package compiler.backend.wasm;

import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrInstruction;
import compiler.ir.model.IrFunction;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir.IrValue;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmModule.WasmLocal;

typedef WasmFunctionRepresentationContext = {
	final allocateLocal:WasmValueType->Int;
	final exceptionTag:Null<Int>;
	final irFunction:Null<IrFunction>;
}

enum WasmLoweringKind {
	Handled(instructions:Array<WasmInstruction>);
	UseDefault;
}

abstract WasmLoweringResult(WasmLoweringKind) from WasmLoweringKind {
	@:from static function fromInstructions(instructions:Array<WasmInstruction>):WasmLoweringResult
		return Handled(instructions);
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
	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int,
			rightLocal:Int):Array<WasmInstruction>;
	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):WasmLoweringResult;
}

/** Heap aggregates, arrays, iterators, and enums. */
interface WasmAggregateRepresentation {
	public function newObject(typeName:String, destination:Int):Array<WasmInstruction>;
	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction>;
	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction>;
	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int,
			indexLocal:Int):WasmLoweringResult;
	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int,
			valueLocal:Int):WasmLoweringResult;
	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult;
	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult;
	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult;
	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int,
			iteratorLocal:Int):WasmLoweringResult;
	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int,
			argumentLocals:Array<Int>):WasmLoweringResult;
	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult;
	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int,
			valueLocal:Int):WasmLoweringResult;
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
	public function staticClosure(name:String, type:IrType, tableSlots:Map<String, Int>,
			destination:Int):WasmLoweringResult;
	public function instanceClosure(name:String, type:IrType, tableSlots:Map<String, Int>, receiverLocal:Int,
			destination:Int):WasmLoweringResult;
	public function callClosure(staticType:Int, instanceType:Null<Int>, arguments:Array<IrValue>, closureLocal:Int,
			destination:Int,
			argumentLocals:Array<Int>):WasmLoweringResult;
}

/** Runtime and C-native calls whose ABI depends on the reference model. */
interface WasmInteropRepresentation {
	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):WasmLoweringResult;
	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):WasmLoweringResult;
}

/**
 * What shared lowering asks the reference model beyond single operations: how a reference is tested for null, compared or
 * carried in a lane, the scalar ABI that keeps value objects in locals, and the model's own steps around a function body.
 * Where one model has nothing to add it answers null, an empty list or `UseDefault`, and shared lowering does the default.
 */
interface WasmModelRepresentation {
	/** The instruction that turns a value of `type` on the stack into whether it is null. */
	public function nullTest(type:IrType):WasmInstruction;

	/** Reference identity of the values in `argumentLocals`, stored to `outputLocal`. */
	public function referenceIdentity(argumentLocals:Array<Int>, outputLocal:Int):Array<WasmInstruction>;

	/** Dynamic equality against a constant null, stored to `outputLocal`, or null for the general equality. */
	public function nullEquality(otherLocal:Int, outputLocal:Int):Null<Array<WasmInstruction>>;

	/** What follows the value on the stack when a value of `type` enters (or, with `unpack`, leaves) a reference lane. */
	public function referenceLane(type:IrType, unpack:Bool):Array<WasmInstruction>;

	/** Whether a block with a single phi assigns it on the incoming edge (and folds a constant diamond) instead of staging it. */
	public function assignsSinglePhi():Bool;

	/** The extra locals that hold references of a scalar value place, by the place's value id; the collector roots them. */
	public function scalarReferenceLocals():Map<Int, Array<Int>>;

	/** The instruction lowered against scalar locals, or null when it does not touch a scalar value place. */
	public function scalarLocal(instruction:IrInstruction, locals:Map<Int, Int>):Null<Array<WasmInstruction>>;

	/**
	 * The index of the model's runtime function `name`, which lowering calls. A model that builds its runtime on
	 * demand builds it now; a name the model's runtime does not define is an error.
	 */
	public function runtimeFunction(name:String):Int;

	public function hasScalarCall(name:String):Bool;
	public function scalarCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>, functionIndex:Int):Array<WasmInstruction>;
	public function hasScalarClosure(type:IrType):Bool;
	public function scalarClosureCall(type:IrType, staticType:Int, instanceType:Int, closureLocal:Int, output:IrValue,
			outputLocal:Int, argumentLocals:Array<Int>):Array<WasmInstruction>;
	public function hasScalarVirtual(receiver:IrType, method:String):Bool;
	public function scalarVirtualCall(receiver:IrValue, method:String, receiverLocal:Int, output:IrValue,
			outputLocal:Int,
			arguments:Array<IrValue>, argumentLocals:Array<Int>):Array<WasmInstruction>;

	/**
	 * `body` wrapped so an exception leaving a scalar-ABI method also hands back its receiver, or null when `fn` needs no
	 * wrapper. `cleanup` restores the collector's root frame on the way out where the model has one.
	 */
	public function scalarExceptionWrapper(fn:IrFunction, body:Array<WasmInstruction>, locals:Map<Int, Int>,
			tag:Null<Int>,
			cleanup:Array<WasmInstruction>):Null<Array<WasmInstruction>>;

	/**
	 * What `fn` returns when it leaves with a pending exception (runtime-neutral exceptions), or null for the zero of its
	 * declared result. `takeException` moves the pending exception into its local and clears it.
	 */
	public function pendingExceptionReturn(fn:IrFunction, locals:Map<Int, Int>, exception:Int,
			takeException:Array<WasmInstruction>):Null<Array<WasmInstruction>>;

	/** The descriptor of a static closure the call representation did not build, or null when the model has none. */
	public function staticClosureDescriptor(name:String, type:IrType):Null<Int>;

	/** The helper that adapts a closure made with another representation to `type`, or null when the model needs none. */
	public function closureCastName(type:IrType):Null<String>;

	/** The signature a closure record of `type` carries, or null when the model's closures carry none. */
	public function closureSignatureId(type:IrType):Null<Int>;

	/** The array (or, with `advance`, the next position) of a value iterator; `UseDefault` for the linear-memory layout. */
	public function valueIterator(advance:Bool, iterator:IrValue, destination:Int,
			iteratorLocal:Int):WasmLoweringResult;

	/** A runtime call the interop representation left to shared lowering, or `UseDefault`. */
	public function runtimeCallFallback(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):WasmLoweringResult;

	/** The lowered body with its locals compacted, or null to keep them as they are. */
	public function compactLocals(body:Array<WasmInstruction>, locals:Array<WasmLocal>,
			parameters:Int):Null<{
				body:Array<WasmInstruction>,
				locals:Array<WasmLocal>
			}>;
}

/** Explicit capability set selected once per module and instantiated per function. */
class WasmRepresentationSet {
	public final values:WasmValueRepresentation;
	public final aggregates:WasmAggregateRepresentation;
	public final calls:Null<WasmCallRepresentation>;
	public final interop:Null<WasmInteropRepresentation>;
	public final model:WasmModelRepresentation;

	final makeFunction:Null<WasmFunctionRepresentationContext->WasmRepresentationSet>;

	public function new(values:WasmValueRepresentation, aggregates:WasmAggregateRepresentation,
			calls:Null<WasmCallRepresentation>,
			interop:Null<WasmInteropRepresentation>, model:WasmModelRepresentation,
			makeFunction:Null<WasmFunctionRepresentationContext->WasmRepresentationSet>) {
		this.values = values;
		this.aggregates = aggregates;
		this.calls = calls;
		this.interop = interop;
		this.model = model;
		this.makeFunction = makeFunction;
	}

	public function forFunction(context:WasmFunctionRepresentationContext):WasmRepresentationSet
		return makeFunction == null ? this : makeFunction(context);
}
