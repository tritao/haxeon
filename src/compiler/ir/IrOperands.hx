package compiler.ir;

import compiler.ir.Ir;

/** Canonical value definitions and uses shared by verification and lowering. */
class IrOperands {
	public static function output(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(out, _), ConstVoid(out), ConstInt(out, _), ConstFloat(out, _), ConstString(out, _), StaticDataAddress(out, _), PointerOffset(out, _, _),
				MemoryLoad(out, _, _, _), ConstBool(out, _), ConstNull(out), TypeValue(out, _), ToDyn(out, _), IntToFloat(out, _), IntToInt64(out, _),
				FloatToInt(out, _), FloatToFloat(out, _), SafeCast(out, _), Catch(out), GlobalGet(out, _), Add(out, _, _), Sub(out, _, _), Mul(out, _, _),
				Div(out, _, _), Mod(out, _, _), BitAnd(out, _, _), BitXor(out, _, _), BitOr(out, _, _), ShiftLeft(out, _, _), ShiftRight(out, _, _),
				UnsignedShiftRight(out, _, _), Less(out, _, _), LessEqual(out, _, _), Equal(out, _, _), Call(out, _, _), CNativeCall(out, _, _),
				StaticClosure(out, _), InstanceClosure(out, _, _), CallClosure(out, _, _), ToVirtual(out, _), Upcast(out, _), MethodCall(out, _, _, _, _), NewObject(out, _),
				FieldGet(out, _, _), ArrayGet(out, _, _), ArraySize(out, _), IteratorNew(out, _), IteratorHasNext(out, _), IteratorNext(out, _),
				MakeEnum(out, _, _, _), EnumIndex(out, _), EnumField(out, _, _, _): out;
			case BeginTry(_, _, _), EndTry(_, _), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _), MemoryStore(_, _, _): null;
		};

	/** Shared result for instructions without inputs; callers only iterate the array and never modify it. */
	static final noInputs:Array<IrValue> = [];

	/** Phi inputs are edge uses and are verified separately. */
	public static function inputs(instruction:IrInstruction):Array<IrValue>
		return switch instruction {
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), StaticDataAddress(_, _), ConstBool(_, _), ConstNull(_),
				TypeValue(_, _), BeginTry(_, _, _), EndTry(_, _), Catch(_), GlobalGet(_, _), StaticClosure(_, _), NewObject(_, _): noInputs;
			case ToDyn(_, value), IntToFloat(_, value), IntToInt64(_, value), FloatToInt(_, value), FloatToFloat(_, value), SafeCast(_, value),
				GlobalSet(_, value), InstanceClosure(_, _, value), ToVirtual(_, value), Upcast(_, value), FieldGet(_, value, _), ArraySize(_, value), IteratorNew(_, value),
				IteratorHasNext(_, value), IteratorNext(_, value), EnumIndex(_, value), EnumField(_, value, _, _), MemoryLoad(_, value, _, _): [value];
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitXor(_, a, b), BitOr(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b), FieldSet(a, _, b), ArrayGet(_, a, b),
				PointerOffset(_, a, b): [a, b];
			case ArraySet(array, index, value): [array, index, value];
			case MemoryStore(pointer, value, _): [pointer, value];
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments): arguments;
			case CallClosure(_, receiver, arguments), MethodCall(_, receiver, _, arguments, _): [receiver].concat(arguments);
		};

	/** How many values `inputs` returns for `instruction`, without making the array. */
	public static function count(instruction:IrInstruction):Int
		return switch instruction {
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), StaticDataAddress(_, _), ConstBool(_, _), ConstNull(_),
				TypeValue(_, _), BeginTry(_, _, _), EndTry(_, _), Catch(_), GlobalGet(_, _), StaticClosure(_, _), NewObject(_, _): 0;
			case ToDyn(_, _), IntToFloat(_, _), IntToInt64(_, _), FloatToInt(_, _), FloatToFloat(_, _), SafeCast(_, _), GlobalSet(_, _), InstanceClosure(_, _, _),
				ToVirtual(_, _), Upcast(_, _), FieldGet(_, _, _), ArraySize(_, _), IteratorNew(_, _), IteratorHasNext(_, _), IteratorNext(_, _), EnumIndex(_, _),
				EnumField(_, _, _, _), MemoryLoad(_, _, _, _): 1;
			case Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _), ShiftLeft(_, _, _),
				ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _), Equal(_, _, _), FieldSet(_, _, _), ArrayGet(_, _, _),
				PointerOffset(_, _, _): 2;
			case ArraySet(_, _, _): 3;
			case MemoryStore(_, _, _): 2;
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments): arguments.length;
			case CallClosure(_, _, arguments), MethodCall(_, _, _, arguments, _): 1 + arguments.length;
		};

	/** The `index`th value of `inputs(instruction)` (0 <= index < count(instruction)), without making the array. */
	public static function at(instruction:IrInstruction, index:Int):IrValue
		return switch instruction {
			case ToDyn(_, value), IntToFloat(_, value), IntToInt64(_, value), FloatToInt(_, value), FloatToFloat(_, value), SafeCast(_, value),
				GlobalSet(_, value), InstanceClosure(_, _, value), ToVirtual(_, value), Upcast(_, value), FieldGet(_, value, _), ArraySize(_, value), IteratorNew(_, value),
				IteratorHasNext(_, value), IteratorNext(_, value), EnumIndex(_, value), EnumField(_, value, _, _), MemoryLoad(_, value, _, _): value;
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitXor(_, a, b), BitOr(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b), FieldSet(a, _, b), ArrayGet(_, a, b),
				PointerOffset(_, a, b): index == 0 ? a : b;
			case ArraySet(array, position, value): index == 0 ? array : index == 1 ? position : value;
			case MemoryStore(pointer, value, _): index == 0 ? pointer : value;
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments): arguments[index];
			case CallClosure(_, receiver, arguments), MethodCall(_, receiver, _, arguments, _): index == 0 ? receiver : arguments[index - 1];
			default: throw "IrOperands.at: no input " + index;
		};
}
