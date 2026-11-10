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
				StaticClosure(out, _), InstanceClosure(out, _, _), CallClosure(out, _, _), ToVirtual(out, _), Upcast(out, _), MethodCall(out, _, _, _, _),
				NewObject(out, _), FieldGet(out, _, _), ArrayGet(out, _, _), ArraySize(out, _), IteratorNew(out, _), IteratorHasNext(out, _),
				IteratorNext(out, _), MakeEnum(out, _, _, _), EnumIndex(out, _), EnumField(out, _, _, _): out;
			case BeginTry(_, _, _), EndTry(_, _), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _), MemoryStore(_, _, _): null;
		};

	/** Borrowed empty view and private predicate result; neither array is mutated. */
	static final noInputs:Array<IrValue> = [];

	static final matchedInputs:Array<IrValue> = [];

	/** Phi inputs are edge uses and are verified separately. */
	public static inline function inputs(instruction:IrInstruction):Array<IrValue>
		return operandView(instruction, null);

	/** Tests all SSA values, including phi edge uses, without temporary input arrays. */
	public static inline function anyValue(instruction:IrInstruction, test:IrValue->Bool):Bool {
		var result = output(instruction);
		return (result != null && test(result)) || operandView(instruction, test) == matchedInputs;
	}

	/** A null predicate returns the input view. Otherwise only the two shared predicate results are returned. */
	static function operandView(instruction:IrInstruction, test:Null<IrValue->Bool>):Array<IrValue>
		return switch instruction {
			case Phi(_, inputs):
				if (test == null) noInputs else {
					var found = false;
					for (input in inputs)
						if (test(input.value)) {
							found = true;
							break;
						}
					found ? matchedInputs : noInputs;
				}
			case ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), StaticDataAddress(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _),
				BeginTry(_, _, _), EndTry(_, _), Catch(_), GlobalGet(_, _), StaticClosure(_, _), NewObject(_, _): noInputs;
			case ToDyn(_, value), IntToFloat(_, value), IntToInt64(_, value), FloatToInt(_, value), FloatToFloat(_, value), SafeCast(_, value),
				GlobalSet(_, value), InstanceClosure(_, _, value), ToVirtual(_, value), Upcast(_, value), FieldGet(_, value, _), ArraySize(_, value),
				IteratorNew(_, value), IteratorHasNext(_, value), IteratorNext(_, value), EnumIndex(_, value), EnumField(_, value, _, _),
				MemoryLoad(_, value, _, _):
				test == null ? [value] : test(value) ? matchedInputs : noInputs;
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitXor(_, a, b), BitOr(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a, b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b), FieldSet(a, _, b), ArrayGet(_, a, b),
				PointerOffset(_, a, b), MemoryStore(a, b, _):
				test == null ? [a, b] : test(a) || test(b) ? matchedInputs : noInputs;
			case ArraySet(array, index, value):
				test == null ? [array, index, value] : test(array) || test(index) || test(value) ? matchedInputs : noInputs;
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments):
				if (test == null) arguments else {
					var found = false;
					for (argument in arguments)
						if (test(argument)) {
							found = true;
							break;
						}
					found ? matchedInputs : noInputs;
				}
			case CallClosure(_, receiver, arguments), MethodCall(_, receiver, _, arguments, _):
				if (test == null) [receiver].concat(arguments) else {
					var found = test(receiver);
					if (!found)
						for (argument in arguments)
							if (test(argument)) {
								found = true;
								break;
							}
					found ? matchedInputs : noInputs;
				}
		};
}
