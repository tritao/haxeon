package compiler.hl.lower;

import compiler.hl.HlFunction.HlInstruction;

/** The registers an instruction names, with whether it writes them, and the instruction with its registers renamed. */
class HlRegisters {
	/** Calls `use` with each register `instruction` names, `written` for the one it defines. Reads come before the write. */
	public static function each(instruction:HlInstruction, use:(register:Int, written:Bool) -> Void):Void
		switch instruction {
			case Move(destination, source):
				use(source, false);
				use(destination, true);
			case LoadInt(destination, constant):
				use(destination, true);
			case LoadFloat(destination, constant):
				use(destination, true);
			case LoadString(destination, constant):
				use(destination, true);
			case LoadBool(destination, value):
				use(destination, true);
			case LoadNull(destination):
				use(destination, true);
			case LoadType(destination, type):
				use(destination, true);
			case ToDyn(destination, source):
				use(source, false);
				use(destination, true);
			case ToSFloat(destination, source):
				use(source, false);
				use(destination, true);
			case ToInt(destination, source):
				use(source, false);
				use(destination, true);
			case SafeCast(destination, source):
				use(source, false);
				use(destination, true);
			case UnsafeCast(destination, source):
				use(source, false);
				use(destination, true);
			case Ref(destination, source):
				use(source, false);
				use(destination, true);
			case Unref(destination, reference):
				use(reference, false);
				use(destination, true);
			case Setref(reference, source):
				use(reference, false);
				use(source, false);
			case RefOffset(destination, reference, index):
				use(reference, false);
				use(index, false);
				use(destination, true);
			case Trap(destination, target, preserveExceptionStack):
				use(destination, true);
			case EndTrap(destination, preserveExceptionStack):
				use(destination, false);
			case GlobalGet(destination, global):
				use(destination, true);
			case GlobalSet(global, source):
				use(source, false);
			case Add(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case Sub(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case Mul(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case Div(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case Mod(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case BitAnd(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case BitXor(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case BitOr(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case ShiftLeft(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case ShiftRight(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case UnsignedShiftRight(destination, left, right):
				use(left, false);
				use(right, false);
				use(destination, true);
			case Call0(destination, functionIndex):
				use(destination, true);
			case Call1(destination, functionIndex, argument):
				use(argument, false);
				use(destination, true);
			case Call2(destination, functionIndex, argument1, argument2):
				use(argument1, false);
				use(argument2, false);
				use(destination, true);
			case CallN(destination, functionIndex, arguments):
				for (register in arguments) use(register, false);
				use(destination, true);
			case StaticClosure(destination, functionIndex):
				use(destination, true);
			case InstanceClosure(destination, functionIndex, receiver):
				use(receiver, false);
				use(destination, true);
			case CallClosure(destination, closure, arguments):
				use(closure, false);
				for (register in arguments) use(register, false);
				use(destination, true);
			case NullCheck(register):
				use(register, false);
			case ToVirtual(destination, source):
				use(source, false);
				use(destination, true);
			case CallMethod(destination, method, arguments):
				for (register in arguments) use(register, false);
				use(destination, true);
			case New(destination, type, extra):
				use(destination, true);
			case FieldGet(destination, object, field):
				use(object, false);
				use(destination, true);
			case FieldSet(object, field, source):
				use(object, false);
				use(source, false);
			case ArrayGet(destination, array, index):
				use(array, false);
				use(index, false);
				use(destination, true);
			case ArraySet(array, index, source):
				use(array, false);
				use(index, false);
				use(source, false);
			case GetI8(destination, pointer, offset):
				use(pointer, false);
				use(offset, false);
				use(destination, true);
			case GetI16(destination, pointer, offset):
				use(pointer, false);
				use(offset, false);
				use(destination, true);
			case GetMem(destination, pointer, offset):
				use(pointer, false);
				use(offset, false);
				use(destination, true);
			case SetI8(pointer, offset, source):
				use(pointer, false);
				use(offset, false);
				use(source, false);
			case SetI16(pointer, offset, source):
				use(pointer, false);
				use(offset, false);
				use(source, false);
			case SetMem(pointer, offset, source):
				use(pointer, false);
				use(offset, false);
				use(source, false);
			case ArraySize(destination, array):
				use(array, false);
				use(destination, true);
			case RefData(destination, array):
				use(array, false);
				use(destination, true);
			case MakeEnum(destination, constructor, arguments):
				for (register in arguments) use(register, false);
				use(destination, true);
			case EnumIndex(destination, value):
				use(value, false);
				use(destination, true);
			case EnumField(destination, value, constructor, field):
				use(value, false);
				use(destination, true);
			case JumpSignedLessOrEqual(left, right, target):
				use(left, false);
				use(right, false);
			case JumpSignedLess(left, right, target):
				use(left, false);
				use(right, false);
			case JumpUnsignedLess(left, right, target):
				use(left, false);
				use(right, false);
			case JumpNull(value, target):
				use(value, false);
			case JumpEqual(left, right, target):
				use(left, false);
				use(right, false);
			case JumpTrue(condition, target):
				use(condition, false);
			case JumpFalse(condition, target):
				use(condition, false);
			case JumpSignedGreaterOrEqual(left, right, target):
				use(left, false);
				use(right, false);
			case JumpUnsignedGreaterOrEqual(left, right, target):
				use(left, false);
				use(right, false);
			case JumpSignedGreater(left, right, target):
				use(left, false);
				use(right, false);
			case JumpNotNull(value, target):
				use(value, false);
			case JumpNotEqual(left, right, target):
				use(left, false);
				use(right, false);
			case JumpNotLess(left, right, target):
				use(left, false);
				use(right, false);
			case JumpNotGreaterOrEqual(left, right, target):
				use(left, false);
				use(right, false);
			case Return(register):
				use(register, false);
			case Throw(register):
				use(register, false);
			case Rethrow(register):
				use(register, false);
			default:
		}

	/** `instruction` with every register `register` renamed to `rename(register)`. */
	public static function map(instruction:HlInstruction, rename:Int->Int):HlInstruction
		return switch instruction {
			case Move(destination, source): Move(rename(destination), rename(source));
			case LoadInt(destination, constant): LoadInt(rename(destination), constant);
			case LoadFloat(destination, constant): LoadFloat(rename(destination), constant);
			case LoadString(destination, constant): LoadString(rename(destination), constant);
			case LoadBool(destination, value): LoadBool(rename(destination), value);
			case LoadNull(destination): LoadNull(rename(destination));
			case LoadType(destination, type): LoadType(rename(destination), type);
			case ToDyn(destination, source): ToDyn(rename(destination), rename(source));
			case ToSFloat(destination, source): ToSFloat(rename(destination), rename(source));
			case ToInt(destination, source): ToInt(rename(destination), rename(source));
			case SafeCast(destination, source): SafeCast(rename(destination), rename(source));
			case UnsafeCast(destination, source): UnsafeCast(rename(destination), rename(source));
			case Ref(destination, source): Ref(rename(destination), rename(source));
			case Unref(destination, reference): Unref(rename(destination), rename(reference));
			case Setref(reference, source): Setref(rename(reference), rename(source));
			case RefOffset(destination, reference, index): RefOffset(rename(destination), rename(reference),
				rename(index));
			case Trap(destination, target, preserveExceptionStack): Trap(rename(destination), target,
				preserveExceptionStack);
			case EndTrap(destination, preserveExceptionStack): EndTrap(rename(destination), preserveExceptionStack);
			case GlobalGet(destination, global): GlobalGet(rename(destination), global);
			case GlobalSet(global, source): GlobalSet(global, rename(source));
			case Add(destination, left, right): Add(rename(destination), rename(left), rename(right));
			case Sub(destination, left, right): Sub(rename(destination), rename(left), rename(right));
			case Mul(destination, left, right): Mul(rename(destination), rename(left), rename(right));
			case Div(destination, left, right): Div(rename(destination), rename(left), rename(right));
			case Mod(destination, left, right): Mod(rename(destination), rename(left), rename(right));
			case BitAnd(destination, left, right): BitAnd(rename(destination), rename(left), rename(right));
			case BitXor(destination, left, right): BitXor(rename(destination), rename(left), rename(right));
			case BitOr(destination, left, right): BitOr(rename(destination), rename(left), rename(right));
			case ShiftLeft(destination, left, right): ShiftLeft(rename(destination), rename(left), rename(right));
			case ShiftRight(destination, left, right): ShiftRight(rename(destination), rename(left), rename(right));
			case UnsignedShiftRight(destination, left, right): UnsignedShiftRight(rename(destination), rename(left),
				rename(right));
			case Call0(destination, functionIndex): Call0(rename(destination), functionIndex);
			case Call1(destination, functionIndex, argument): Call1(rename(destination), functionIndex,
				rename(argument));
			case Call2(destination, functionIndex, argument1, argument2): Call2(rename(destination), functionIndex,
				rename(argument1), rename(argument2));
			case CallN(destination, functionIndex, arguments): CallN(rename(destination), functionIndex,
				[for (register in arguments) rename(register)]);
			case StaticClosure(destination, functionIndex): StaticClosure(rename(destination), functionIndex);
			case InstanceClosure(destination, functionIndex, receiver): InstanceClosure(rename(destination),
				functionIndex, rename(receiver));
			case CallClosure(destination, closure, arguments): CallClosure(rename(destination), rename(closure),
				[for (register in arguments) rename(register)]);
			case NullCheck(register): NullCheck(rename(register));
			case ToVirtual(destination, source): ToVirtual(rename(destination), rename(source));
			case CallMethod(destination, method, arguments): CallMethod(rename(destination), method,
				[for (register in arguments) rename(register)]);
			case New(destination, type, extra): New(rename(destination), type, extra);
			case FieldGet(destination, object, field): FieldGet(rename(destination), rename(object), field);
			case FieldSet(object, field, source): FieldSet(rename(object), field, rename(source));
			case ArrayGet(destination, array, index): ArrayGet(rename(destination), rename(array), rename(index));
			case ArraySet(array, index, source): ArraySet(rename(array), rename(index), rename(source));
			case GetI8(destination, pointer, offset): GetI8(rename(destination), rename(pointer), rename(offset));
			case GetI16(destination, pointer, offset): GetI16(rename(destination), rename(pointer), rename(offset));
			case GetMem(destination, pointer, offset): GetMem(rename(destination), rename(pointer), rename(offset));
			case SetI8(pointer, offset, source): SetI8(rename(pointer), rename(offset), rename(source));
			case SetI16(pointer, offset, source): SetI16(rename(pointer), rename(offset), rename(source));
			case SetMem(pointer, offset, source): SetMem(rename(pointer), rename(offset), rename(source));
			case ArraySize(destination, array): ArraySize(rename(destination), rename(array));
			case RefData(destination, array): RefData(rename(destination), rename(array));
			case MakeEnum(destination, constructor, arguments): MakeEnum(rename(destination), constructor,
				[for (register in arguments) rename(register)]);
			case EnumIndex(destination, value): EnumIndex(rename(destination), rename(value));
			case EnumField(destination, value, constructor, field): EnumField(rename(destination), rename(value),
				constructor, field);
			case JumpSignedLessOrEqual(left, right, target): JumpSignedLessOrEqual(rename(left), rename(right), target);
			case JumpSignedLess(left, right, target): JumpSignedLess(rename(left), rename(right), target);
			case JumpUnsignedLess(left, right, target): JumpUnsignedLess(rename(left), rename(right), target);
			case JumpNull(value, target): JumpNull(rename(value), target);
			case JumpEqual(left, right, target): JumpEqual(rename(left), rename(right), target);
			case JumpTrue(condition, target): JumpTrue(rename(condition), target);
			case JumpFalse(condition, target): JumpFalse(rename(condition), target);
			case JumpSignedGreaterOrEqual(left, right, target): JumpSignedGreaterOrEqual(rename(left), rename(right),
				target);
			case JumpUnsignedGreaterOrEqual(left, right, target): JumpUnsignedGreaterOrEqual(rename(left),
				rename(right), target);
			case JumpSignedGreater(left, right, target): JumpSignedGreater(rename(left), rename(right), target);
			case JumpNotNull(value, target): JumpNotNull(rename(value), target);
			case JumpNotEqual(left, right, target): JumpNotEqual(rename(left), rename(right), target);
			case JumpNotLess(left, right, target): JumpNotLess(rename(left), rename(right), target);
			case JumpNotGreaterOrEqual(left, right, target): JumpNotGreaterOrEqual(rename(left), rename(right), target);
			case Return(register): Return(rename(register));
			case Throw(register): Throw(rename(register));
			case Rethrow(register): Rethrow(rename(register));
			default: instruction;
		};
}
