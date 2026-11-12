package compiler.ir.codec;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrFunction.IrValueArraySlotOperation;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Conservative, allocation-light equality of all state encoded by IrFunctionStateCodec. */
class IrFunctionStateEquality {
	public static function same(left:IrFunction, right:IrFunction):Bool {
		if (left == right)
			return true;
		if (left.name != right.name
			|| !sameKind(left.kind, right.kind)
			|| left.inlineHint != right.inlineHint
			|| left.retention != right.retention
			|| !IrVerifier.sameType(left.result, right.result)
			|| left.arguments.length != right.arguments.length
			|| left.blocks.length != right.blocks.length
			|| left.debugBindings.length != right.debugBindings.length)
			return false;
		for (i in 0...left.arguments.length)
			if (!value(left.arguments[i], right.arguments[i]))
				return false;
		for (i in 0...left.debugBindings.length) {
			var a = left.debugBindings[i], b = right.debugBindings[i];
			if (a.identity != b.identity || a.name != b.name || a.path != b.path || a.scopeStart != b.scopeStart || a.scopeEnd != b.scopeEnd
				|| !value(a.value, b.value))
				return false;
		}
		for (i in 0...left.blocks.length) {
			var a = left.blocks[i], b = right.blocks[i];
			if (a == b)
				continue;
			if (a.id != b.id || a.instructions.length != b.instructions.length)
				return false;
			for (j in 0...a.instructions.length) {
				var x = a.instructions[j], y = b.instructions[j];
				if (x != y && (!provenance(x.provenance, y.provenance) || !instruction(x.value, y.value)))
					return false;
			}
			var x = a.terminator, y = b.terminator;
			if (x != y && (x == null || y == null || !provenance(x.provenance, y.provenance) || !terminator(x.value, y.value)))
				return false;
		}
		return true;
	}

	static function sameKind(a:compiler.ir.IrFunction.IrFunctionKind, b:compiler.ir.IrFunction.IrFunctionKind):Bool
		return switch [a, b] {
			case [Ordinary, Ordinary]: true;
			case [GenericSpecialization, GenericSpecialization]: true;
			case [SourceLambda, SourceLambda]: true;
			case [IterationAdapter, IterationAdapter]: true;
			case [GeneratedHelper, GeneratedHelper]: true;
			case [Provider(aSubject, aOperation), Provider(bSubject, bOperation)]: aSubject == bSubject && aOperation == bOperation;
			case [OptionalScalar(aOrigin), OptionalScalar(bOrigin)]: aOrigin == bOrigin;
			case [NullableScalarArguments, NullableScalarArguments]: true;
			case [EnumEquality(aReflective), EnumEquality(bReflective)]: aReflective == bReflective;
			case [EnumDynamicUnbox(a), EnumDynamicUnbox(b)]: IrVerifier.sameType(a, b);
			case [EnumTagAdapter(a, ab), EnumTagAdapter(b, bb)]: ab == bb && IrVerifier.sameType(a, b);
			case [ValueArraySlot(aNamespace, aElement, aOperation), ValueArraySlot(bNamespace, bElement, bOperation)]:
				aNamespace == bNamespace && IrVerifier.sameType(aElement, bElement) && sameSlotOperation(aOperation, bOperation);
			case [WasmClosureRestore, WasmClosureRestore]: true;
			case [ScalarArguments, ScalarArguments]: true;
			case [ClosureAdapter(aSource, aTarget), ClosureAdapter(bSource, bTarget)]:
				IrVerifier.sameType(aSource, bSource) && IrVerifier.sameType(aTarget, bTarget);
			case [ClosureCast(aTarget), ClosureCast(bTarget)]: IrVerifier.sameType(aTarget, bTarget);
			case [ClosureVarargs(aTarget), ClosureVarargs(bTarget)]: IrVerifier.sameType(aTarget, bTarget);
			default: false;
		};

	static function sameSlotPath(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	static function sameSlotOperation(a:IrValueArraySlotOperation, b:IrValueArraySlotOperation):Bool
		return switch [a, b] {
			case [Read(ai, ap, ac), Read(bi, bp, bc)], [Write(ai, ap, ac), Write(bi, bp, bc)]:
				ai == bi && ac == bc && sameSlotPath(ap, bp);
			case [Check(ap, ai), Check(bp, bi)]: ai == bi && sameSlotPath(ap, bp);
			case [OptionalWrite(ap, at), OptionalWrite(bp, bt)]: sameSlotPath(ap, bp) && IrVerifier.sameType(at, bt);
			case [RequireScalar(at), RequireScalar(bt)]: IrVerifier.sameType(at, bt);
			default: false;
		};

	static function value(a:IrValue, b:IrValue):Bool
		return a == b || (a.id == b.id && a.name == b.name && IrVerifier.sameType(a.type, b.type));

	static function provenance(a:SourceProvenance, b:SourceProvenance):Bool {
		if (a == b)
			return true;
		if (!origin(a.origin, b.origin))
			return false;
		var x = a.location, y = b.location;
		return x == y
			|| (x != null && y != null && x.path == y.path && x.start == y.start && x.end == y.end && x.line == y.line && x.column == y.column
				&& x.endLine == y.endLine && x.endColumn == y.endColumn && x.sourceHash == y.sourceHash);
	}

	static function origin(a:SourceOrigin, b:SourceOrigin):Bool
		return switch [a, b] {
			case [UserSource, UserSource]: true;
			case [CompilerGenerated(x), CompilerGenerated(y)]: x == y;
			default: false;
		};

	static function instruction(a:IrInstruction, b:IrInstruction):Bool
		return switch a {
			case Phi(output, inputs): switch b {
				case Phi(other, otherInputs): value(output, other) && phiInputs(inputs, otherInputs);
				default: false;
			};
			case ConstVoid(output): switch b {
				case ConstVoid(other): value(output, other);
				default: false;
			};
			case ConstNull(output): switch b {
				case ConstNull(other): value(output, other);
				default: false;
			};
			case Catch(output): switch b {
				case Catch(other): value(output, other);
				default: false;
			};
			case ConstInt(output, number): switch b {
				case ConstInt(other, otherNumber): value(output, other) && number == otherNumber;
				default: false;
			};
			case ConstFloat(output, number): switch b {
				case ConstFloat(other, otherNumber): value(output, other) && sameFloat(number, otherNumber);
				default: false;
			};
			case ConstString(output, text): switch b {
				case ConstString(other, otherText): value(output, other) && text == otherText;
				default: false;
			};
			case StaticDataAddress(output, bytes): switch b {
				case StaticDataAddress(other, otherBytes): value(output, other) && integers(bytes, otherBytes);
				default: false;
			};
			case PointerOffset(output, pointer, offset): switch b {
				case PointerOffset(otherOutput, otherPointer, otherOffset): value(output, otherOutput) && value(pointer, otherPointer) && value(offset, otherOffset);
				default: false;
			};
			case MemoryLoad(output, pointer, size, signed): switch b {
				case MemoryLoad(otherOutput, otherPointer, otherSize, otherSigned): value(output, otherOutput) && value(pointer, otherPointer) && size == otherSize && signed == otherSigned;
				default: false;
			};
			case MemoryStore(pointer, stored, size): switch b {
				case MemoryStore(otherPointer, otherStored, otherSize): value(pointer, otherPointer) && value(stored, otherStored) && size == otherSize;
				default: false;
			};
			case ConstBool(output, state): switch b {
				case ConstBool(other, otherState): value(output, other) && state == otherState;
				default: false;
			};
			case TypeValue(output, type): switch b {
				case TypeValue(other, otherType): value(output, other) && IrVerifier.sameType(type, otherType);
				default: false;
			};
			case ToDyn(output, input): switch b {
				case ToDyn(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case IntToFloat(output, input): switch b {
				case IntToFloat(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case IntToInt64(output, input): switch b {
				case IntToInt64(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case FloatToInt(output, input): switch b {
				case FloatToInt(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case FloatToFloat(output, input): switch b {
				case FloatToFloat(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case SafeCast(output, input): switch b {
				case SafeCast(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case BeginTry(catchBlock, afterBlock, preserve): switch b {
				case BeginTry(otherCatch, otherAfter, otherPreserve): catchBlock == otherCatch && afterBlock == otherAfter && preserve == otherPreserve;
				default: false;
			};
			case EndTry(catchBlock, preserve): switch b {
				case EndTry(otherCatch, otherPreserve): catchBlock == otherCatch && preserve == otherPreserve;
				default: false;
			};
			case GlobalGet(output, name): switch b {
				case GlobalGet(otherOutput, otherName): value(output, otherOutput) && name == otherName;
				default: false;
			};
			case GlobalSet(name, stored): switch b {
				case GlobalSet(otherName, otherStored): name == otherName && value(stored, otherStored);
				default: false;
			};
			case Add(output, left, right): switch b {
				case Add(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Sub(output, left, right): switch b {
				case Sub(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Mul(output, left, right): switch b {
				case Mul(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Div(output, left, right): switch b {
				case Div(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Mod(output, left, right): switch b {
				case Mod(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case BitAnd(output, left, right): switch b {
				case BitAnd(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case BitXor(output, left, right): switch b {
				case BitXor(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case BitOr(output, left, right): switch b {
				case BitOr(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case ShiftLeft(output, left, right): switch b {
				case ShiftLeft(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case ShiftRight(output, left, right): switch b {
				case ShiftRight(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case UnsignedShiftRight(output, left, right): switch b {
				case UnsignedShiftRight(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Less(output, left, right): switch b {
				case Less(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case LessEqual(output, left, right): switch b {
				case LessEqual(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Equal(output, left, right): switch b {
				case Equal(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft) && value(right, otherRight);
				default: false;
			};
			case Call(output, name, arguments): switch b {
				case Call(otherOutput, otherName, otherArguments): value(output, otherOutput) && name == otherName && values(arguments, otherArguments);
				default: false;
			};
			case Intrinsic(output, operation, arguments): switch b {
				case Intrinsic(otherOutput, otherOperation, otherArguments):
					value(output, otherOutput) && values(arguments, otherArguments) && switch [operation, otherOperation] {
						case [EnumDynamicBox(aType), EnumDynamicBox(bType)], [EnumDynamicView(aType), EnumDynamicView(bType)],
							[EnumTagBox(aType), EnumTagBox(bType)], [EnumTagUnbox(aType), EnumTagUnbox(bType)],
							[InlineEnumBox(aType), InlineEnumBox(bType)], [InlineEnumUnbox(aType), InlineEnumUnbox(bType)]:
							IrVerifier.sameType(aType, bType);
						default: false;
					};
				default: false;
			};
			case CNativeCall(output, name, arguments): switch b {
				case CNativeCall(otherOutput, otherName, otherArguments): value(output, otherOutput) && name == otherName && values(arguments, otherArguments);
				default: false;
			};
			case StaticClosure(output, name): switch b {
				case StaticClosure(otherOutput, otherName): value(output, otherOutput) && name == otherName;
				default: false;
			};
			case InstanceClosure(output, name, receiver): switch b {
				case InstanceClosure(otherOutput, otherName, otherReceiver): value(output, otherOutput) && name == otherName && value(receiver, otherReceiver);
				default: false;
			};
			case CallClosure(output, closure, arguments): switch b {
				case CallClosure(otherOutput, otherClosure, otherArguments): value(output, otherOutput) && value(closure, otherClosure) && values(arguments, otherArguments);
				default: false;
			};
			case ToVirtual(output, input): switch b {
				case ToVirtual(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case ClassId(output, input): switch b {
				case ClassId(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case Upcast(output, input): switch b {
				case Upcast(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case MethodCall(output, object, name, arguments, terminal): switch b {
				case MethodCall(otherOutput, otherObject, otherName, otherArguments, otherTerminal): value(output, otherOutput) && value(object, otherObject) && name == otherName && values(arguments, otherArguments) && terminal == otherTerminal;
				default: false;
			};
			case NewObject(output, name): switch b {
				case NewObject(otherOutput, otherName): value(output, otherOutput) && name == otherName;
				default: false;
			};
			case FieldGet(output, object, name): switch b {
				case FieldGet(otherOutput, otherObject, otherName): value(output, otherOutput) && value(object, otherObject) && name == otherName;
				default: false;
			};
			case FieldSet(object, name, stored): switch b {
				case FieldSet(otherObject, otherName, otherStored): value(object, otherObject) && name == otherName && value(stored, otherStored);
				default: false;
			};
			case ArrayGet(output, array, index): switch b {
				case ArrayGet(otherOutput, otherArray, otherIndex): value(output, otherOutput) && value(array, otherArray) && value(index, otherIndex);
				default: false;
			};
			case ArraySet(array, index, stored): switch b {
				case ArraySet(otherArray, otherIndex, otherStored): value(array, otherArray) && value(index, otherIndex) && value(stored, otherStored);
				default: false;
			};
			case ArraySize(output, array): switch b {
				case ArraySize(otherOutput, otherArray): value(output, otherOutput) && value(array, otherArray);
				default: false;
			};
			case IteratorNew(output, array): switch b {
				case IteratorNew(otherOutput, otherArray): value(output, otherOutput) && value(array, otherArray);
				default: false;
			};
			case IteratorHasNext(output, iterator): switch b {
				case IteratorHasNext(otherOutput, otherIterator): value(output, otherOutput) && value(iterator, otherIterator);
				default: false;
			};
			case IteratorNext(output, iterator): switch b {
				case IteratorNext(otherOutput, otherIterator): value(output, otherOutput) && value(iterator, otherIterator);
				default: false;
			};
			case MakeEnum(output, name, constructor, arguments): switch b {
				case MakeEnum(otherOutput, otherName, otherConstructor, otherArguments): value(output, otherOutput) && name == otherName && constructor == otherConstructor && values(arguments, otherArguments);
				default: false;
			};
			case EnumIndex(output, input): switch b {
				case EnumIndex(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
				default: false;
			};
			case EnumField(output, input, constructor, field): switch b {
				case EnumField(otherOutput, otherInput, otherConstructor, otherField): value(output, otherOutput) && value(input, otherInput) && constructor == otherConstructor && field == otherField;
				default: false;
			};
		};

	static function terminator(a:IrTerminator, b:IrTerminator):Bool
		return switch a {
			case Unreachable: switch b {
				case Unreachable: true;
				default: false;
			};
			case Return(input): switch b {
				case Return(other): value(input, other);
				default: false;
			};
			case Throw(input): switch b {
				case Throw(other): value(input, other);
				default: false;
			};
			case Rethrow(input): switch b {
				case Rethrow(other): value(input, other);
				default: false;
			};
			case Jump(target): switch b {
				case Jump(other): target == other;
				default: false;
			};
			case Branch(condition, whenTrue, whenFalse): switch b {
				case Branch(otherCondition, otherTrue, otherFalse): value(condition, otherCondition) && whenTrue == otherTrue && whenFalse == otherFalse;
				default: false;
			};
		};

	static function values(a:Array<IrValue>, b:Array<IrValue>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (!value(a[i], b[i]))
				return false;
		return true;
	}

	static function phiInputs(a:Array<IrPhiInput>, b:Array<IrPhiInput>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length) {
			var x = a[i], y = b[i];
			if (x.block != y.block || !value(x.value, y.value))
				return false;
		}
		return true;
	}

	static function integers(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (a[i] != b[i])
				return false;
		return true;
	}

	static function sameFloat(a:Float, b:Float):Bool {
		// IEEE equality equates -0 with +0 and cannot distinguish NaN payloads; the state codec preserves their bits.
		#if haxeon
		return runtime.FloatBits.toInt64(a) == runtime.FloatBits.toInt64(b);
		#else
		var x = haxe.io.FPHelper.doubleToI64(a), y = haxe.io.FPHelper.doubleToI64(b);
		return x.high == y.high && x.low == y.low;
		#end
	}
}
