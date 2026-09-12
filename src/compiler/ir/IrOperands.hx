package compiler.ir;

import compiler.ir.Ir;

/** Canonical value definitions and uses shared by verification and lowering. */
class IrOperands {
	public static function output(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(out, _), ConstVoid(out), ConstInt(out, _), ConstFloat(out, _), ConstString(out, _), ConstBool(out, _), ConstNull(out), TypeValue(out, _),
				ToDyn(out, _), IntToFloat(out, _), IntToInt64(out, _), FloatToInt(out, _), SafeCast(out, _), Catch(out), GlobalGet(out, _), Add(out, _, _),
				Sub(out, _, _), Mul(out, _, _), Div(out, _, _), Mod(out, _, _), BitAnd(out, _, _), BitXor(out, _, _), BitOr(out, _, _), ShiftLeft(out, _, _),
				ShiftRight(out, _, _), UnsignedShiftRight(out, _, _), Less(out, _, _), LessEqual(out, _, _), Equal(out, _, _), Call(out, _, _),
				CNativeCall(out, _, _), StaticClosure(out, _), InstanceClosure(out, _, _), CallClosure(out, _, _), ToVirtual(out, _),
				MethodCall(out, _, _, _), NewObject(out, _), FieldGet(out, _, _), ArrayGet(out, _, _), ArraySize(out, _), IteratorNew(out, _),
				IteratorHasNext(out, _), IteratorNext(out, _), MakeEnum(out, _, _, _), EnumIndex(out, _), EnumField(out, _, _, _): out;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _): null;
		};

	/** Phi inputs are edge uses and are verified separately. */
	public static function inputs(instruction:IrInstruction):Array<IrValue>
		return switch instruction {
			case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _), BeginTry(_, _),
				EndTry(_), Catch(_), GlobalGet(_, _), StaticClosure(_, _), NewObject(_, _): [];
			case ToDyn(_, value), IntToFloat(_, value), IntToInt64(_, value), FloatToInt(_, value), SafeCast(_, value), GlobalSet(_, value),
				InstanceClosure(_, _, value), ToVirtual(_, value), FieldGet(_, value, _), ArraySize(_, value), IteratorNew(_, value),
				IteratorHasNext(_, value), IteratorNext(_, value), EnumIndex(_, value), EnumField(_, value, _, _): [value];
			case Add(_, a, b), Sub(_, a, b), Mul(_, a, b), Div(_, a, b), Mod(_, a, b), BitAnd(_, a, b), BitXor(_, a, b), BitOr(_, a, b), ShiftLeft(_, a, b),
				ShiftRight(_, a,
					b), UnsignedShiftRight(_, a, b), Less(_, a, b), LessEqual(_, a, b), Equal(_, a, b), FieldSet(a, _, b), ArrayGet(_, a, b): [a, b];
			case ArraySet(array, index, value): [array, index, value];
			case Call(_, _, arguments), CNativeCall(_, _, arguments), MakeEnum(_, _, _, arguments): arguments;
			case CallClosure(_, receiver, arguments), MethodCall(_, receiver, _, arguments): [receiver].concat(arguments);
		};
}
