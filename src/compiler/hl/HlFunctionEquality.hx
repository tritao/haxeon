package compiler.hl;

import compiler.hl.HlFunction.HlInstruction;

/** Structural comparison of two lowered functions: type, slot, registers, opcodes, debug locations and assignments. */
class HlFunctionEquality {
	/** Null when the functions are the same; otherwise the first difference. */
	public static function difference(a:HlFunction, b:HlFunction):Null<String> {
		if (a.type != b.type)
			return 'type ${a.type} and ${b.type}';
		if (a.functionIndex != b.functionIndex)
			return 'slot ${a.functionIndex} and ${b.functionIndex}';
		if (a.registers.length != b.registers.length)
			return 'register counts ${a.registers.length} and ${b.registers.length}';
		for (index in 0...a.registers.length)
			if (a.registers[index] != b.registers[index])
				return 'register $index is type ${a.registers[index]} and ${b.registers[index]}';
		// Jump targets and labels are strings; lowering again numbers its generated ones from a counter of its own, so two functions
		// are the same when their labels correspond one to one.
		var forward:Map<String, String> = [],
			backward:Map<String, String> = [];
		if (a.opcodes.length != b.opcodes.length)
			return 'opcode counts ${a.opcodes.length} and ${b.opcodes.length}';
		for (index in 0...a.opcodes.length)
			if (!same(a.opcodes[index], b.opcodes[index], forward, backward))
				return 'opcode $index is ${a.opcodes[index]} and ${b.opcodes[index]}';
		if (a.debugLocations.length != b.debugLocations.length)
			return 'debug location counts ${a.debugLocations.length} and ${b.debugLocations.length}';
		for (index in 0...a.debugLocations.length) {
			var x = a.debugLocations[index], y = b.debugLocations[index];
			if (x != y
				&& (x.path != y.path || x.line != y.line || x.column != y.column || x.endLine != y.endLine || x.endColumn != y.endColumn
					|| x.sourceHash != y.sourceHash || x.start != y.start || x.end != y.end || x.flags != y.flags))
				return 'debug location $index differs';
		}
		if (a.debugAssignments.length != b.debugAssignments.length)
			return 'debug assignment counts ${a.debugAssignments.length} and ${b.debugAssignments.length}';
		for (index in 0...a.debugAssignments.length) {
			var x = a.debugAssignments[index], y = b.debugAssignments[index];
			if (x.name != y.name || x.position != y.position || x.scopeEnd != y.scopeEnd)
				return 'debug assignment $index differs';
		}
		return null;
	}

	/** Compare every opcode explicitly; a new constructor must add its operand comparison here. */
	static function same(a:HlInstruction, b:HlInstruction, forward:Map<String, String>, backward:Map<String, String>):Bool {
		return switch a {
			case Move(destination, source):
				switch b {
					case Move(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case LoadInt(destination, constant):
				switch b {
					case LoadInt(otherDestination, otherConstant): destination == otherDestination && constant == otherConstant;
					default: false;
				}
			case LoadFloat(destination, constant):
				switch b {
					case LoadFloat(otherDestination, otherConstant): destination == otherDestination && constant == otherConstant;
					default: false;
				}
			case LoadString(destination, constant):
				switch b {
					case LoadString(otherDestination, otherConstant): destination == otherDestination && constant == otherConstant;
					default: false;
				}
			case LoadBool(destination, value):
				switch b {
					case LoadBool(otherDestination, otherValue): destination == otherDestination && value == otherValue;
					default: false;
				}
			case LoadNull(destination):
				switch b {
					case LoadNull(otherDestination): destination == otherDestination;
					default: false;
				}
			case LoadType(destination, type):
				switch b {
					case LoadType(otherDestination, otherType): destination == otherDestination && type == otherType;
					default: false;
				}
			case ToDyn(destination, source):
				switch b {
					case ToDyn(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case ToSFloat(destination, source):
				switch b {
					case ToSFloat(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case ToInt(destination, source):
				switch b {
					case ToInt(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case SafeCast(destination, source):
				switch b {
					case SafeCast(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case UnsafeCast(destination, source):
				switch b {
					case UnsafeCast(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case Ref(destination, source):
				switch b {
					case Ref(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case Unref(destination, reference):
				switch b {
					case Unref(otherDestination, otherReference): destination == otherDestination && reference == otherReference;
					default: false;
				}
			case Setref(reference, source):
				switch b {
					case Setref(otherReference, otherSource): reference == otherReference && source == otherSource;
					default: false;
				}
			case RefOffset(destination, reference, index):
				switch b {
					case RefOffset(otherDestination, otherReference, otherIndex): destination == otherDestination && reference == otherReference && index == otherIndex;
					default: false;
				}
			case Trap(destination, target, preserveExceptionStack):
				switch b {
					case Trap(otherDestination, otherTarget, otherPreserveExceptionStack): destination == otherDestination && sameLabel(target, otherTarget, forward, backward) && preserveExceptionStack == otherPreserveExceptionStack;
					default: false;
				}
			case EndTrap(destination, preserveExceptionStack):
				switch b {
					case EndTrap(otherDestination, otherPreserveExceptionStack): destination == otherDestination && preserveExceptionStack == otherPreserveExceptionStack;
					default: false;
				}
			case GlobalGet(destination, global):
				switch b {
					case GlobalGet(otherDestination, otherGlobal): destination == otherDestination && global == otherGlobal;
					default: false;
				}
			case GlobalSet(global, source):
				switch b {
					case GlobalSet(otherGlobal, otherSource): global == otherGlobal && source == otherSource;
					default: false;
				}
			case Add(destination, left, right):
				switch b {
					case Add(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case Sub(destination, left, right):
				switch b {
					case Sub(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case Mul(destination, left, right):
				switch b {
					case Mul(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case Div(destination, left, right):
				switch b {
					case Div(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case Mod(destination, left, right):
				switch b {
					case Mod(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case BitAnd(destination, left, right):
				switch b {
					case BitAnd(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case BitXor(destination, left, right):
				switch b {
					case BitXor(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case BitOr(destination, left, right):
				switch b {
					case BitOr(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case ShiftLeft(destination, left, right):
				switch b {
					case ShiftLeft(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case ShiftRight(destination, left, right):
				switch b {
					case ShiftRight(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case UnsignedShiftRight(destination, left, right):
				switch b {
					case UnsignedShiftRight(otherDestination, otherLeft, otherRight): destination == otherDestination && left == otherLeft && right == otherRight;
					default: false;
				}
			case Call0(destination, functionIndex):
				switch b {
					case Call0(otherDestination, otherFunctionIndex): destination == otherDestination && functionIndex == otherFunctionIndex;
					default: false;
				}
			case Call1(destination, functionIndex, argument):
				switch b {
					case Call1(otherDestination, otherFunctionIndex, otherArgument): destination == otherDestination && functionIndex == otherFunctionIndex && argument == otherArgument;
					default: false;
				}
			case Call2(destination, functionIndex, argument1, argument2):
				switch b {
					case Call2(otherDestination, otherFunctionIndex, otherArgument1, otherArgument2): destination == otherDestination && functionIndex == otherFunctionIndex && argument1 == otherArgument1 && argument2 == otherArgument2;
					default: false;
				}
			case CallN(destination, functionIndex, arguments):
				switch b {
					case CallN(otherDestination, otherFunctionIndex, otherArguments): destination == otherDestination && functionIndex == otherFunctionIndex && sameRegisters(arguments, otherArguments);
					default: false;
				}
			case StaticClosure(destination, functionIndex):
				switch b {
					case StaticClosure(otherDestination, otherFunctionIndex): destination == otherDestination && functionIndex == otherFunctionIndex;
					default: false;
				}
			case InstanceClosure(destination, functionIndex, receiver):
				switch b {
					case InstanceClosure(otherDestination, otherFunctionIndex, otherReceiver): destination == otherDestination && functionIndex == otherFunctionIndex && receiver == otherReceiver;
					default: false;
				}
			case CallClosure(destination, closure, arguments):
				switch b {
					case CallClosure(otherDestination, otherClosure, otherArguments): destination == otherDestination && closure == otherClosure && sameRegisters(arguments, otherArguments);
					default: false;
				}
			case NullCheck(register):
				switch b {
					case NullCheck(otherRegister): register == otherRegister;
					default: false;
				}
			case ToVirtual(destination, source):
				switch b {
					case ToVirtual(otherDestination, otherSource): destination == otherDestination && source == otherSource;
					default: false;
				}
			case CallMethod(destination, method, arguments):
				switch b {
					case CallMethod(otherDestination, otherMethod, otherArguments): destination == otherDestination && method == otherMethod && sameRegisters(arguments, otherArguments);
					default: false;
				}
			case New(destination, type, extra):
				switch b {
					case New(otherDestination, otherType, otherExtra): destination == otherDestination && type == otherType && extra == otherExtra;
					default: false;
				}
			case FieldGet(destination, object, field):
				switch b {
					case FieldGet(otherDestination, otherObject, otherField): destination == otherDestination && object == otherObject && field == otherField;
					default: false;
				}
			case FieldSet(object, field, source):
				switch b {
					case FieldSet(otherObject, otherField, otherSource): object == otherObject && field == otherField && source == otherSource;
					default: false;
				}
			case ArrayGet(destination, array, index):
				switch b {
					case ArrayGet(otherDestination, otherArray, otherIndex): destination == otherDestination && array == otherArray && index == otherIndex;
					default: false;
				}
			case ArraySet(array, index, source):
				switch b {
					case ArraySet(otherArray, otherIndex, otherSource): array == otherArray && index == otherIndex && source == otherSource;
					default: false;
				}
			case GetI8(destination, pointer, offset):
				switch b {
					case GetI8(otherDestination, otherPointer, otherOffset): destination == otherDestination && pointer == otherPointer && offset == otherOffset;
					default: false;
				}
			case GetI16(destination, pointer, offset):
				switch b {
					case GetI16(otherDestination, otherPointer, otherOffset): destination == otherDestination && pointer == otherPointer && offset == otherOffset;
					default: false;
				}
			case GetMem(destination, pointer, offset):
				switch b {
					case GetMem(otherDestination, otherPointer, otherOffset): destination == otherDestination && pointer == otherPointer && offset == otherOffset;
					default: false;
				}
			case SetI8(pointer, offset, source):
				switch b {
					case SetI8(otherPointer, otherOffset, otherSource): pointer == otherPointer && offset == otherOffset && source == otherSource;
					default: false;
				}
			case SetI16(pointer, offset, source):
				switch b {
					case SetI16(otherPointer, otherOffset, otherSource): pointer == otherPointer && offset == otherOffset && source == otherSource;
					default: false;
				}
			case SetMem(pointer, offset, source):
				switch b {
					case SetMem(otherPointer, otherOffset, otherSource): pointer == otherPointer && offset == otherOffset && source == otherSource;
					default: false;
				}
			case ArraySize(destination, array):
				switch b {
					case ArraySize(otherDestination, otherArray): destination == otherDestination && array == otherArray;
					default: false;
				}
			case RefData(destination, array):
				switch b {
					case RefData(otherDestination, otherArray): destination == otherDestination && array == otherArray;
					default: false;
				}
			case MakeEnum(destination, constructor, arguments):
				switch b {
					case MakeEnum(otherDestination, otherConstructor, otherArguments): destination == otherDestination && constructor == otherConstructor && sameRegisters(arguments, otherArguments);
					default: false;
				}
			case EnumIndex(destination, value):
				switch b {
					case EnumIndex(otherDestination, otherValue): destination == otherDestination && value == otherValue;
					default: false;
				}
			case EnumField(destination, value, constructor, field):
				switch b {
					case EnumField(otherDestination, otherValue, otherConstructor, otherField): destination == otherDestination && value == otherValue && constructor == otherConstructor && field == otherField;
					default: false;
				}
			case JumpSignedLessOrEqual(left, right, target):
				switch b {
					case JumpSignedLessOrEqual(otherLeft, otherRight, otherTarget): left == otherLeft && right == otherRight && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case JumpSignedLess(left, right, target):
				switch b {
					case JumpSignedLess(otherLeft, otherRight, otherTarget): left == otherLeft && right == otherRight && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case JumpUnsignedLess(left, right, target):
				switch b {
					case JumpUnsignedLess(otherLeft, otherRight, otherTarget): left == otherLeft && right == otherRight && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case JumpNull(value, target):
				switch b {
					case JumpNull(otherValue, otherTarget): value == otherValue && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case JumpEqual(left, right, target):
				switch b {
					case JumpEqual(otherLeft, otherRight, otherTarget): left == otherLeft && right == otherRight && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case JumpTrue(condition, target):
				switch b {
					case JumpTrue(otherCondition, otherTarget): condition == otherCondition && sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case Jump(target):
				switch b {
					case Jump(otherTarget): sameLabel(target, otherTarget, forward, backward);
					default: false;
				}
			case Label(name):
				switch b {
					case Label(otherName): sameLabel(name, otherName, forward, backward);
					default: false;
				}
			case Return(register):
				switch b {
					case Return(otherRegister): register == otherRegister;
					default: false;
				}
			case Throw(register):
				switch b {
					case Throw(otherRegister): register == otherRegister;
					default: false;
				}
			case Rethrow(register):
				switch b {
					case Rethrow(otherRegister): register == otherRegister;
					default: false;
				}
		};
	}

	static function sameRegisters(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length)
			return false;
		for (index in 0...a.length)
			if (a[index] != b[index])
				return false;
		return true;
	}

	static function sameLabel(a:String, b:String, forward:Map<String, String>, backward:Map<String, String>):Bool {
		var mapped = forward.get(a), origin = backward.get(b);
		if (mapped == null && origin == null) {
			forward.set(a, b);
			backward.set(b, a);
			return true;
		}
		return mapped == b && origin == a;
	}
}
