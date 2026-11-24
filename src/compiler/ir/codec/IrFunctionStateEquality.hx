package compiler.ir.codec;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrFunction.IrValueArraySlotOperation;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.verify.IrVerifier;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.SourceOrigin;

/**
 * Conservative, allocation-light equality of all state encoded by IrFunctionStateCodec.
 *
 * `same` compares everything. `sameCode` leaves out where the code sits in its file: each location's whole-file content hash and
 * byte offsets, and each debug binding's scope offsets. Those move with any edit before the function, so an edit anywhere in a
 * file would make every later function of it look different; lines and columns still count, so a function whose lines moved
 * differs and its stack traces stay right. Two functions with the same code that are not `same` only moved within their file:
 * one cannot stand in for the other in a build, whose debug information must name the source snapshot it carries. Neither
 * decodes a body: a function compared with a body is encoded instead.
 */
@:nullSafety(Strict)
class IrFunctionStateEquality {
	public static inline function same(left:IrFunction, right:IrFunction):Bool
		return compare(left, right, true);

	/** Whether `left` and `right` run the same code on the same lines, wherever their file placed them (see the class). */
	public static inline function sameCode(left:IrFunction, right:IrFunction):Bool
		return compare(left, right, false);

	/** `same` with `placed`, or `sameCode` without. */
	static function compare(left:IrFunction, right:IrFunction, placed:Bool):Bool {
		if (left == right)
			return true;
		var leftBody = left.body, rightBody = right.body;
		if (leftBody != null && rightBody != null)
			return compareBodies(leftBody, rightBody, placed);
		// One that is its body alone (a session releases the objects of what it keeps frozen, `IrFunction.releaseDecoded`) is not
		// decoded: the other is encoded and the bodies compared, after the header shows they could be the same.
		if (leftBody != null || rightBody != null) {
			if (left.name != right.name || left.arguments.length != right.arguments.length
				|| !IrVerifier.sameType(left.result, right.result))
				return false;
			if (leftBody != null)
				return compareBodies(leftBody, IrBodyBuilder.encode(right), placed);
			if (rightBody != null)
				return compareBodies(IrBodyBuilder.encode(left), rightBody, placed);
		}
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
			if (a.identity != b.identity || a.name != b.name || a.path != b.path
				|| placed && (a.scopeStart != b.scopeStart || a.scopeEnd != b.scopeEnd)
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
				if (x != y && (!provenance(x.provenance, y.provenance, placed) || !instruction(x.value, y.value)))
					return false;
			}
			var x = a.terminator, y = b.terminator;
			if (x != y) {
				if (x == null || y == null)
					return false;
				if (!provenance(x.provenance, y.provenance, placed) || !terminator(x.value, y.value))
					return false;
			}
		}
		return true;
	}

	/** `same` on two functions that are bodies (`IrFunction.ofBody`), read as rows, so neither is decoded. */
	public static inline function sameBodies(left:IrBody, right:IrBody):Bool
		return compareBodies(left, right, true);

	/** `sameCode` on two bodies. */
	public static inline function sameBodyCode(left:IrBody, right:IrBody):Bool
		return compareBodies(left, right, false);

	static function compareBodies(left:IrBody, right:IrBody, placed:Bool):Bool {
		if (left == right)
			return true;
		if (left.name != right.name
			|| !sameKind(left.kind, right.kind)
			|| left.inlineHint != right.inlineHint
			|| left.retention != right.retention
			|| !IrVerifier.sameType(IrTypeIds.type(left.result), IrTypeIds.type(right.result))
			|| left.argumentCount() != right.argumentCount()
			|| left.blockCount() != right.blockCount()
			|| left.bindingCount() != right.bindingCount())
			return false;
		for (i in 0...left.argumentCount())
			if (!bodyValue(left, left.argument(i), right, right.argument(i)))
				return false;
		for (i in 0...left.bindingCount())
			if (left.bindingIdentity(i) != right.bindingIdentity(i)
				|| left.bindingName(i) != right.bindingName(i)
				|| left.bindingPath(i) != right.bindingPath(i)
				|| placed && (left.bindingScopeStart(i) != right.bindingScopeStart(i)
				|| left.bindingScopeEnd(i) != right.bindingScopeEnd(i))
				|| !bodyValue(left, left.bindingValue(i), right, right.bindingValue(i)))
				return false;
		for (block in 0...left.blockCount()) {
			if (left.blockId(block) != right.blockId(block))
				return false;
			var x = left.firstRow(block), y = right.firstRow(block);
			while (x >= 0 || y >= 0) {
				if (x < 0 || y < 0 || !sameRow(left, x, right, y, placed))
					return false;
				x = left.nextRow(x);
				y = right.nextRow(y);
			}
		}
		return true;
	}

	static function bodyValue(left:IrBody, a:IrValueId, right:IrBody, b:IrValueId):Bool
		return (a:Int) == (b:Int) && left.valueName(a) == right.valueName(b)
			&& IrVerifier.sameType(left.valueType(a), right.valueType(b));

	/** Whether row `x` of `left` and row `y` of `right` are the same instruction or terminator, from the same place. */
	static function sameRow(left:IrBody, x:Int, right:IrBody, y:Int, placed:Bool):Bool {
		var opcode = left.opcode(x);
		if (opcode != right.opcode(y) || !provenance(left.provenance(x), right.provenance(y), placed))
			return false;
		var a = left.output(x), b = right.output(y);
		if (a.exists() != b.exists() || a.exists() && !bodyValue(left, a, right, b))
			return false;
		var count = left.operandCount(x);
		if (count != right.operandCount(y))
			return false;
		for (index in 0...count)
			if (!bodyValue(left, left.operand(x, index), right, right.operand(y, index)))
				return false;
		var ints = switch opcode {
			case IrOpcode.ConstFloat: return sameFloat(left.float(x), right.float(y));
			case IrOpcode.ConstString: return left.string(x) == right.string(y);
			case IrOpcode.TypeValue, IrOpcode.EnumDynamicBox, IrOpcode.EnumDynamicView, IrOpcode.EnumTagBox,
				IrOpcode.EnumTagUnbox, IrOpcode.InlineEnumBox, IrOpcode.InlineEnumUnbox:
				return IrVerifier.sameType(left.typeOperand(x), right.typeOperand(y));
			case IrOpcode.Phi: count;
			case IrOpcode.StaticDataAddress: 1 + left.auxInt(x, 0);
			case IrOpcode.BeginTry: 3;
			case IrOpcode.EndTry, IrOpcode.MakeEnum, IrOpcode.EnumField, IrOpcode.Branch: 2;
			case IrOpcode.Switch: 2 + left.auxInt(x, 1);
			default: return left.aux(x) == right.aux(y);
		};
		for (index in 0...ints)
			if (left.auxInt(x, index) != right.auxInt(y, index))
				return false;
		return true;
	}

	/** Where two functions first differ, as `same` compares them, or null when they are the same; for error messages. */
	public static function difference(left:IrFunction, right:IrFunction):Null<String> {
		if (same(left, right))
			return null;
		if (left.name != right.name)
			return 'name ${left.name} / ${right.name}';
		if (!sameKind(left.kind, right.kind))
			return 'kind ${left.kind} / ${right.kind}';
		if (left.inlineHint != right.inlineHint || left.retention != right.retention)
			return "inline hint or retention";
		if (!IrVerifier.sameType(left.result, right.result))
			return 'result ${left.result} / ${right.result}';
		if (left.arguments.length != right.arguments.length)
			return 'argument count ${left.arguments.length} / ${right.arguments.length}';
		for (i in 0...left.arguments.length)
			if (!value(left.arguments[i], right.arguments[i]))
				return 'argument $i: ${describe(left.arguments[i])} / ${describe(right.arguments[i])}';
		if (left.debugBindings.length != right.debugBindings.length)
			return 'debug binding count ${left.debugBindings.length} / ${right.debugBindings.length}';
		for (i in 0...left.debugBindings.length) {
			var a = left.debugBindings[i], b = right.debugBindings[i];
			if (a.identity != b.identity || a.name != b.name || a.path != b.path || a.scopeStart != b.scopeStart
				|| a.scopeEnd != b.scopeEnd
				|| !value(a.value, b.value))
				return 'debug binding $i: ${a.name} ${describe(a.value)} / ${b.name} ${describe(b.value)}';
		}
		if (left.blocks.length != right.blocks.length)
			return 'block count ${left.blocks.length} / ${right.blocks.length}';
		for (i in 0...left.blocks.length) {
			var a = left.blocks[i], b = right.blocks[i];
			if (a.id != b.id)
				return 'block $i id ${a.id} / ${b.id}';
			if (a.instructions.length != b.instructions.length)
				return 'block ${a.id} instruction count ${a.instructions.length} / ${b.instructions.length}';
			for (j in 0...a.instructions.length) {
				var x = a.instructions[j], y = b.instructions[j];
				if (!instruction(x.value, y.value))
					return 'block ${a.id} instruction $j: ${x.value} / ${y.value}';
				if (!provenance(x.provenance, y.provenance, true))
					return 'block ${a.id} instruction $j provenance';
			}
			var x = a.terminator, y = b.terminator;
			if (x == null || y == null) {
				if (x != y)
					return 'block ${a.id} terminator presence';
			} else if (!terminator(x.value, y.value))
				return 'block ${a.id} terminator: ${x.value} / ${y.value}';
			else if (!provenance(x.provenance, y.provenance, true))
				return 'block ${a.id} terminator provenance';
		}
		return "unlocated";
	}

	static function describe(value:IrValue):String
		return 'value ${value.id} "${value.name}" ${value.type}';

	public static function sameKind(a:compiler.ir.model.IrFunction.IrFunctionKind,
			b:compiler.ir.model.IrFunction.IrFunctionKind):Bool
		return switch [a, b] {
			case [Ordinary, Ordinary]: true;
			case [GenericSpecialization, GenericSpecialization]: true;
			case [SourceLambda, SourceLambda]: true;
			case [IterationAdapter, IterationAdapter]: true;
			case [GeneratedHelper, GeneratedHelper]: true;
			case [Provider(aSubject, aOperation), Provider(bSubject, bOperation)]: aSubject == bSubject
				&& aOperation == bOperation;
			case [OptionalScalar(aOrigin), OptionalScalar(bOrigin)]: aOrigin == bOrigin;
			case [NullableScalarArguments, NullableScalarArguments]: true;
			case [EnumEquality(aReflective), EnumEquality(bReflective)]: aReflective == bReflective;
			case [EnumDynamicUnbox(a), EnumDynamicUnbox(b)]: IrVerifier.sameType(a, b);
			case [EnumTagAdapter(a, ab), EnumTagAdapter(b, bb)]: ab == bb && IrVerifier.sameType(a, b);
			case [
				ValueArraySlot(aNamespace, aElement, aOperation),
				ValueArraySlot(bNamespace, bElement, bOperation)
			]: aNamespace == bNamespace && IrVerifier.sameType(aElement, bElement)
				&& sameSlotOperation(aOperation, bOperation);
			case [WasmClosureRestore, WasmClosureRestore]: true;
			case [ScalarArguments, ScalarArguments]: true;
			case [ClosureAdapter(aSource, aTarget), ClosureAdapter(bSource, bTarget)]: IrVerifier.sameType(aSource,
				bSource) && IrVerifier.sameType(aTarget, bTarget);
			case [ClosureCast(aTarget), ClosureCast(bTarget)]: IrVerifier.sameType(aTarget, bTarget);
			case [ClosureVarargs(aTarget), ClosureVarargs(bTarget)]: IrVerifier.sameType(aTarget, bTarget);
			default: false;
		};

	static function sameSlotPath(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (a[i] != b[i])
				return false;
		return true;
	}

	static function sameSlotOperation(a:IrValueArraySlotOperation, b:IrValueArraySlotOperation):Bool
		return switch [a, b] {
			case [Read(ai, ap, ac), Read(bi, bp, bc)],
				[Write(ai, ap, ac), Write(bi, bp, bc)]: ai == bi && ac == bc && sameSlotPath(ap, bp);
			case [Check(ap, ai), Check(bp, bi)]: ai == bi && sameSlotPath(ap, bp);
			case [OptionalWrite(ap, at), OptionalWrite(bp, bt)]: sameSlotPath(ap, bp) && IrVerifier.sameType(at, bt);
			case [RequireScalar(at), RequireScalar(bt)]: IrVerifier.sameType(at, bt);
			default: false;
		};

	static function value(a:IrValue, b:IrValue):Bool
		return a == b || (a.id == b.id && a.name == b.name && IrVerifier.sameType(a.type, b.type));

	static function provenance(a:SourceProvenance, b:SourceProvenance, placed:Bool):Bool {
		if (a == b)
			return true;
		if (!origin(a.origin, b.origin))
			return false;
		var x = a.location, y = b.location;
		return x == y
			|| (x != null && y != null && x.path == y.path && x.line == y.line && x.column == y.column
			&& x.endLine == y.endLine && x.endColumn == y.endColumn
			&& (!placed || x.start == y.start && x.end == y.end && x.sourceHash == y.sourceHash));
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
					case PointerOffset(otherOutput, otherPointer, otherOffset): value(output,
						otherOutput) && value(pointer, otherPointer) && value(offset, otherOffset);
					default: false;
				};
			case MemoryLoad(output, pointer, size, signed): switch b {
					case MemoryLoad(otherOutput, otherPointer, otherSize, otherSigned): value(output,
						otherOutput) && value(pointer, otherPointer) && size == otherSize && signed == otherSigned;
					default: false;
				};
			case MemoryStore(pointer, stored, size): switch b {
					case MemoryStore(otherPointer, otherStored, otherSize): value(pointer, otherPointer)
						&& value(stored, otherStored) && size == otherSize;
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
					case BeginTry(otherCatch, otherAfter, otherPreserve): catchBlock == otherCatch
						&& afterBlock == otherAfter && preserve == otherPreserve;
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
					case Add(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case Sub(output, left, right): switch b {
					case Sub(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case Mul(output, left, right): switch b {
					case Mul(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case Div(output, left, right): switch b {
					case Div(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case Mod(output, left, right): switch b {
					case Mod(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case BitAnd(output, left, right): switch b {
					case BitAnd(otherOutput, otherLeft, otherRight): value(output, otherOutput)
						&& value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case BitXor(output, left, right): switch b {
					case BitXor(otherOutput, otherLeft, otherRight): value(output, otherOutput)
						&& value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case BitOr(output, left, right): switch b {
					case BitOr(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case ShiftLeft(output, left, right): switch b {
					case ShiftLeft(otherOutput, otherLeft, otherRight): value(output, otherOutput)
						&& value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case ShiftRight(output, left, right): switch b {
					case ShiftRight(otherOutput, otherLeft, otherRight): value(output, otherOutput)
						&& value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case UnsignedShiftRight(output, left, right): switch b {
					case UnsignedShiftRight(otherOutput, otherLeft, otherRight): value(output,
						otherOutput) && value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case Less(output, left, right): switch b {
					case Less(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case LessEqual(output, left, right): switch b {
					case LessEqual(otherOutput, otherLeft, otherRight): value(output, otherOutput)
						&& value(left, otherLeft) && value(right, otherRight);
					default: false;
				};
			case Equal(output, left, right): switch b {
					case Equal(otherOutput, otherLeft, otherRight): value(output, otherOutput) && value(left, otherLeft)
						&& value(right, otherRight);
					default: false;
				};
			case Call(output, name, arguments): switch b {
					case Call(otherOutput, otherName, otherArguments): value(output, otherOutput) && name == otherName
						&& values(arguments, otherArguments);
					default: false;
				};
			case Intrinsic(output, operation, arguments): switch b {
					case Intrinsic(otherOutput, otherOperation, otherArguments): value(output,
						otherOutput) && values(arguments, otherArguments) && switch [
							operation,
							otherOperation
						] {
							case [EnumDynamicBox(aType), EnumDynamicBox(bType)], [
								EnumDynamicView(aType),
								EnumDynamicView(bType)
							],
								[
									EnumTagBox(aType),
									EnumTagBox(bType)
								], [
									EnumTagUnbox(aType),
									EnumTagUnbox(bType)
								],
								[
									InlineEnumBox(aType),
									InlineEnumBox(bType)
								], [
									InlineEnumUnbox(aType),
									InlineEnumUnbox(bType)
								]:
								IrVerifier.sameType(aType, bType);
							default: false;
						};
					default: false;
				};
			case CNativeCall(output, name, arguments): switch b {
					case CNativeCall(otherOutput, otherName, otherArguments): value(output,
						otherOutput) && name == otherName && values(arguments, otherArguments);
					default: false;
				};
			case StaticClosure(output, name): switch b {
					case StaticClosure(otherOutput, otherName): value(output, otherOutput) && name == otherName;
					default: false;
				};
			case InstanceClosure(output, name, receiver): switch b {
					case InstanceClosure(otherOutput, otherName, otherReceiver): value(output,
						otherOutput) && name == otherName && value(receiver, otherReceiver);
					default: false;
				};
			case CallClosure(output, closure, arguments): switch b {
					case CallClosure(otherOutput, otherClosure, otherArguments): value(output,
						otherOutput) && value(closure, otherClosure) && values(arguments, otherArguments);
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
					case MethodCall(otherOutput, otherObject, otherName, otherArguments, otherTerminal):
						value(output, otherOutput)
							&& value(object, otherObject)
							&& name == otherName
							&& values(arguments, otherArguments)
							&& terminal == otherTerminal;
					default: false;
				};
			case NewObject(output, name): switch b {
					case NewObject(otherOutput, otherName): value(output, otherOutput) && name == otherName;
					default: false;
				};
			case ValueInit(output): switch b {
					case ValueInit(otherOutput): value(output, otherOutput);
					default: false;
				};
			case FieldGet(output, object, name): switch b {
					case FieldGet(otherOutput, otherObject, otherName): value(output, otherOutput)
						&& value(object, otherObject) && name == otherName;
					default: false;
				};
			case FieldSet(object, name, stored): switch b {
					case FieldSet(otherObject, otherName, otherStored): value(object, otherObject) && name == otherName
						&& value(stored, otherStored);
					default: false;
				};
			case ArrayGet(output, array, index): switch b {
					case ArrayGet(otherOutput, otherArray, otherIndex): value(output, otherOutput)
						&& value(array, otherArray) && value(index, otherIndex);
					default: false;
				};
			case ArraySet(array, index, stored): switch b {
					case ArraySet(otherArray, otherIndex, otherStored): value(array, otherArray)
						&& value(index, otherIndex) && value(stored, otherStored);
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
					case IteratorHasNext(otherOutput, otherIterator): value(output, otherOutput)
						&& value(iterator, otherIterator);
					default: false;
				};
			case IteratorNext(output, iterator): switch b {
					case IteratorNext(otherOutput, otherIterator): value(output, otherOutput)
						&& value(iterator, otherIterator);
					default: false;
				};
			case MakeEnum(output, name, constructor, arguments): switch b {
					case MakeEnum(otherOutput, otherName, otherConstructor, otherArguments): value(output,
						otherOutput) && name == otherName && constructor == otherConstructor
						&& values(arguments, otherArguments);
					default: false;
				};
			case EnumIndex(output, input): switch b {
					case EnumIndex(otherOutput, otherInput): value(output, otherOutput) && value(input, otherInput);
					default: false;
				};
			case EnumField(output, input, constructor, field): switch b {
					case EnumField(otherOutput, otherInput, otherConstructor, otherField): value(output,
						otherOutput) && value(input, otherInput) && constructor == otherConstructor
						&& field == otherField;
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
					case Branch(otherCondition, otherTrue, otherFalse): value(condition, otherCondition)
						&& whenTrue == otherTrue && whenFalse == otherFalse;
					default: false;
				};
			case Switch(input, targets, otherwise): switch b {
					case Switch(other, otherTargets, otherOtherwise): value(input, other) && otherwise == otherOtherwise
						&& targets.length == otherTargets.length && [for (index in 0...targets.length)
						if (targets[index] != otherTargets[index]) index].length == 0;
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
		var x = haxe.io.FPHelper.doubleToI64(a),
			y = haxe.io.FPHelper.doubleToI64(b);
		return x.high == y.high && x.low == y.low;
		#end
	}
}
