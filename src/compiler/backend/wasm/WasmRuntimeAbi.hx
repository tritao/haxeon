package compiler.backend.wasm;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrProgram;

/** Semantic operations shared by linear-memory and future Wasm-GC runtimes. */
enum WasmRuntimeOperation {
	AllocateObject;
	GetField;
	SetField;
	AllocateArray;
	MapOperation;
	GetArray;
	SetArray;
	ArraySize;
	IteratorOperation;
	MakeClosure;
	CallClosure;
	MethodDispatch;
	DynamicConversion;
	TypeCheck;
	EnumConstruction;
	EnumAccess;
	StringOperation;
	NativeCall;
	Throw;
	Catch;
	Allocate;
}

class WasmRuntimeAbi {
	public static inline final VERSION:Int = 2;

	public static function operations(program:IrProgram):Array<WasmRuntimeOperation> {
		var seen:Map<String, Bool> = [],
			result:Array<WasmRuntimeOperation> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions) {
					var operation:Null<WasmRuntimeOperation> = operationOf(located.value);
					if (operation != null && !seen.exists(Std.string(operation))) {
						seen.set(Std.string(operation), true);
						result.push(operation);
					}
				}
		result.sort(function(left, right) return Reflect.compare(Std.string(left), Std.string(right)));
		return result;
	}

	static function operationOf(instruction:IrInstruction):Null<WasmRuntimeOperation>
		return switch instruction {
			case NewObject(_, _): AllocateObject;
			case FieldGet(_, _, _): GetField;
			case FieldSet(_, _, _): SetField;
			case ArrayGet(_, _, _): GetArray;
			case ArraySet(_, _, _): SetArray;
			case ArraySize(_, _): ArraySize;
			case IteratorNew(_, _), IteratorHasNext(_, _), IteratorNext(_, _): IteratorOperation;
			case StaticClosure(_, _), InstanceClosure(_, _, _): MakeClosure;
			case CallClosure(_, _, _): CallClosure;
			case MethodCall(_, _, _, _), ToVirtual(_, _): MethodDispatch;
			case ToDyn(_, _), SafeCast(_, _): DynamicConversion;
			case TypeValue(_, _): TypeCheck;
			case MakeEnum(_, _, _, _): EnumConstruction;
			case EnumIndex(_, _), EnumField(_, _, _, _): EnumAccess;
			case ConstString(_, _): StringOperation;
			case CNativeCall(_, _, _): NativeCall;
			case BeginTry(_, _), EndTry(_): Catch;
			case Call(_, name, _) if (StringTools.startsWith(name, "__array_alloc_")): AllocateArray;
			case Call(_, name, _) if (StringTools.startsWith(name, "__array_")): Allocate;
			case Call(_, name, _) if (StringTools.startsWith(name, "__map_")): MapOperation;
			case Call(_, name, _) if (StringTools.startsWith(name, "__string_")): StringOperation;
			case Call(_, "__haxeon_alloc", _): Allocate;
			default: null;
		};
}
