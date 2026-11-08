package compiler.ir.codec;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Conservative, allocation-light equality of all state encoded by IrFunctionStateCodec. */
class IrFunctionStateEquality {
	public static function same(left:IrFunction, right:IrFunction):Bool {
		if (left == right)
			return true;
		if (left.name != right.name
			|| left.inlineHint != right.inlineHint
			|| left.retention != right.retention
			|| !sameType(left.result, right.result)
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

	static function value(a:IrValue, b:IrValue):Bool
		return a == b || (a.id == b.id && a.name == b.name && sameType(a.type, b.type));

	static function sameType(a:IrType, b:IrType):Bool
		return switch [a, b] {
			case [Void, Void], [I32, I32], [I64, I64], [Bool, Bool], [F32, F32], [F64, F64], [Bytes, Bytes], [RawPtr, RawPtr],
				[ManagedBytes, ManagedBytes], [Dyn, Dyn], [TypeRef, TypeRef]: true;
			case [Nullable(x), Nullable(y)], [Array(x), Array(y)], [Iterator(x), Iterator(y)]: sameType(x, y);
			case [Enum(x), Enum(y)], [Obj(x), Obj(y)], [Abstract(x), Abstract(y)], [Virtual(x), Virtual(y)]: x == y;
			case [Function(xArguments, xResult), Function(yArguments, yResult)]:
				types(xArguments, yArguments) && sameType(xResult, yResult);
			default: false;
		};

	static function types(a:Array<IrType>, b:Array<IrType>):Bool {
		if (a.length != b.length)
			return false;
		for (i in 0...a.length)
			if (!sameType(a[i], b[i]))
				return false;
		return true;
	}

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
		return switch [a, b] {
			case [Phi(xOutput, xInputs), Phi(yOutput, yInputs)]: value(xOutput, yOutput) && phiInputs(xInputs, yInputs);
			case [ConstVoid(x), ConstVoid(y)], [ConstNull(x), ConstNull(y)], [Catch(x), Catch(y)]: value(x, y);
			case [ConstInt(xOutput, x), ConstInt(yOutput, y)]: value(xOutput, yOutput) && x == y;
			case [ConstFloat(xOutput, x), ConstFloat(yOutput, y)]: value(xOutput, yOutput) && sameFloat(x, y);
			case [ConstString(xOutput, x), ConstString(yOutput, y)]: value(xOutput, yOutput) && x == y;
			case [StaticDataAddress(xOutput, x), StaticDataAddress(yOutput, y)]: value(xOutput, yOutput) && integers(x, y);
			case [PointerOffset(xOutput, xPointer, xOffset), PointerOffset(yOutput, yPointer, yOffset)]:
				value(xOutput, yOutput) && value(xPointer, yPointer) && value(xOffset, yOffset);
			case [MemoryLoad(xOutput, xPointer, xSize, xSigned), MemoryLoad(yOutput, yPointer, ySize, ySigned)]:
				value(xOutput, yOutput) && value(xPointer, yPointer) && xSize == ySize && xSigned == ySigned;
			case [MemoryStore(xPointer, xValue, xSize), MemoryStore(yPointer, yValue, ySize)]:
				value(xPointer, yPointer) && value(xValue, yValue) && xSize == ySize;
			case [ConstBool(xOutput, x), ConstBool(yOutput, y)]: value(xOutput, yOutput) && x == y;
			case [TypeValue(xOutput, x), TypeValue(yOutput, y)]: value(xOutput, yOutput) && sameType(x, y);
			case [ToDyn(xOutput, x), ToDyn(yOutput, y)], [IntToFloat(xOutput, x), IntToFloat(yOutput, y)],
				[IntToInt64(xOutput, x), IntToInt64(yOutput, y)], [FloatToInt(xOutput, x), FloatToInt(yOutput, y)],
				[FloatToFloat(xOutput, x), FloatToFloat(yOutput, y)], [SafeCast(xOutput, x), SafeCast(yOutput, y)],
				[ToVirtual(xOutput, x), ToVirtual(yOutput, y)], [Upcast(xOutput, x), Upcast(yOutput, y)]:
				value(xOutput, yOutput) && value(x, y);
			case [BeginTry(xCatch, xAfter, xPreserve), BeginTry(yCatch, yAfter, yPreserve)]:
				xCatch == yCatch && xAfter == yAfter && xPreserve == yPreserve;
			case [EndTry(xCatch, xPreserve), EndTry(yCatch, yPreserve)]: xCatch == yCatch && xPreserve == yPreserve;
			case [GlobalGet(xOutput, x), GlobalGet(yOutput, y)]: value(xOutput, yOutput) && x == y;
			case [GlobalSet(x, xValue), GlobalSet(y, yValue)]: x == y && value(xValue, yValue);
			case [Add(xOutput, xLeft, xRight), Add(yOutput, yLeft, yRight)], [Sub(xOutput, xLeft, xRight), Sub(yOutput, yLeft, yRight)],
				[Mul(xOutput, xLeft, xRight), Mul(yOutput, yLeft, yRight)], [Div(xOutput, xLeft, xRight), Div(yOutput, yLeft, yRight)],
				[Mod(xOutput, xLeft, xRight), Mod(yOutput, yLeft, yRight)], [BitAnd(xOutput, xLeft, xRight), BitAnd(yOutput, yLeft, yRight)],
				[BitXor(xOutput, xLeft, xRight), BitXor(yOutput, yLeft, yRight)], [BitOr(xOutput, xLeft, xRight), BitOr(yOutput, yLeft, yRight)],
				[ShiftLeft(xOutput, xLeft, xRight), ShiftLeft(yOutput, yLeft, yRight)],
				[ShiftRight(xOutput, xLeft, xRight), ShiftRight(yOutput, yLeft, yRight)],
				[UnsignedShiftRight(xOutput, xLeft, xRight), UnsignedShiftRight(yOutput, yLeft, yRight)],
				[Less(xOutput, xLeft, xRight), Less(yOutput, yLeft, yRight)],
				[LessEqual(xOutput, xLeft, xRight), LessEqual(yOutput, yLeft, yRight)],
				[Equal(xOutput, xLeft, xRight), Equal(yOutput, yLeft, yRight)]:
				value(xOutput, yOutput) && value(xLeft, yLeft) && value(xRight, yRight);
			case [Call(xOutput, xName, xArguments), Call(yOutput, yName, yArguments)],
				[CNativeCall(xOutput, xName, xArguments), CNativeCall(yOutput, yName, yArguments)]:
				value(xOutput, yOutput) && xName == yName && values(xArguments, yArguments);
			case [StaticClosure(xOutput, xName), StaticClosure(yOutput, yName)]: value(xOutput, yOutput) && xName == yName;
			case [InstanceClosure(xOutput, xName, xReceiver), InstanceClosure(yOutput, yName, yReceiver)]:
				value(xOutput, yOutput) && xName == yName && value(xReceiver, yReceiver);
			case [CallClosure(xOutput, xClosure, xArguments), CallClosure(yOutput, yClosure, yArguments)]:
				value(xOutput, yOutput) && value(xClosure, yClosure) && values(xArguments, yArguments);
			case [MethodCall(xOutput, xObject, xName, xArguments, xTerminal), MethodCall(yOutput, yObject, yName, yArguments, yTerminal)]:
				value(xOutput, yOutput) && value(xObject, yObject) && xName == yName && values(xArguments, yArguments) && xTerminal == yTerminal;
			case [NewObject(xOutput, xName), NewObject(yOutput, yName)]: value(xOutput, yOutput) && xName == yName;
			case [FieldGet(xOutput, xObject, xName), FieldGet(yOutput, yObject, yName)]:
				value(xOutput, yOutput) && value(xObject, yObject) && xName == yName;
			case [FieldSet(xObject, xName, xValue), FieldSet(yObject, yName, yValue)]: value(xObject, yObject) && xName == yName && value(xValue, yValue);
			case [ArrayGet(xOutput, xArray, xIndex), ArrayGet(yOutput, yArray, yIndex)]:
				value(xOutput, yOutput) && value(xArray, yArray) && value(xIndex, yIndex);
			case [ArraySet(xArray, xIndex, xValue), ArraySet(yArray, yIndex, yValue)]:
				value(xArray, yArray) && value(xIndex, yIndex) && value(xValue, yValue);
			case [ArraySize(xOutput, xArray), ArraySize(yOutput, yArray)], [IteratorNew(xOutput, xArray), IteratorNew(yOutput, yArray)],
				[IteratorHasNext(xOutput, xArray), IteratorHasNext(yOutput, yArray)],
				[IteratorNext(xOutput, xArray), IteratorNext(yOutput, yArray)]: value(xOutput, yOutput) && value(xArray, yArray);
			case [MakeEnum(xOutput, xName, xConstructor, xArguments), MakeEnum(yOutput, yName, yConstructor, yArguments)]:
				value(xOutput, yOutput) && xName == yName && xConstructor == yConstructor && values(xArguments, yArguments);
			case [EnumIndex(xOutput, xValue), EnumIndex(yOutput, yValue)]: value(xOutput, yOutput) && value(xValue, yValue);
			case [EnumField(xOutput, xValue, xConstructor, xField), EnumField(yOutput, yValue, yConstructor, yField)]:
				value(xOutput, yOutput) && value(xValue, yValue) && xConstructor == yConstructor && xField == yField;
			default: false;
		};

	static function terminator(a:IrTerminator, b:IrTerminator):Bool
		return switch [a, b] {
			case [Return(x), Return(y)], [Throw(x), Throw(y)], [Rethrow(x), Rethrow(y)]: value(x, y);
			case [Jump(x), Jump(y)]: x == y;
			case [Branch(xCondition, xTrue, xFalse), Branch(yCondition, yTrue, yFalse)]:
				value(xCondition, yCondition) && xTrue == yTrue && xFalse == yFalse;
			default: false;
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
