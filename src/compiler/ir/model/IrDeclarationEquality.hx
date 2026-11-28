package compiler.ir.model;

import compiler.ir.model.Ir;

/**
 * Whether two declarations of one name read the same, part by part: what a memo that recorded a declaration as an answer
 * (verification's and lowering's facts, `IrVerifyAnswers`, `HlLoweringView`) and the pipeline's root (`PipelineSnapshot`)
 * compare it by: the parts the canonical encoding writes (`CanonicalIrCodec.encodeTables`). A declaration is never changed once
 * made, and the stages make new ones every build, so the same object is the fast case and the parts decide the rest.
 */
@:nullSafety(Strict)
class IrDeclarationEquality {
	/** Every part of an `IrObject`. */
	public static function sameObject(a:IrObject, b:IrObject):Bool {
		if (a == b)
			return true;
		if (a.name != b.name || a.isValue != b.isValue || a.base != b.base
			|| !sameNativeLayout(a.nativeLayout, b.nativeLayout) || !sameNames(a.interfaces, b.interfaces)
			|| a.fields.length != b.fields.length || a.methods.length != b.methods.length)
			return false;
		for (index in 0...a.fields.length) {
			var left = a.fields[index], right = b.fields[index];
			if (left.name != right.name || !IrTypeIdentity.same(left.type, right.type)
				|| !sameFieldLayout(left.nativeLayout, right.nativeLayout)
				|| !sameStorage(left.scalarStorage, right.scalarStorage)
				|| !sameStorage(left.nullableScalarStorage, right.nullableScalarStorage))
				return false;
		}
		for (index in 0...a.methods.length) {
			var left = a.methods[index], right = b.methods[index];
			if (left.name != right.name || left.functionName != right.functionName)
				return false;
		}
		return true;
	}

	/** Every part of an `IrInterface`. */
	public static function sameInterface(a:IrInterface, b:IrInterface):Bool {
		if (a == b)
			return true;
		if (a.name != b.name || !sameNames(a.bases, b.bases) || a.methods.length != b.methods.length)
			return false;
		for (index in 0...a.methods.length) {
			var left = a.methods[index], right = b.methods[index];
			if (left.name != right.name || !sameTypes(left.arguments, right.arguments)
				|| !IrTypeIdentity.same(left.result, right.result))
				return false;
		}
		return true;
	}

	/** Every part of an `IrEnum`. */
	public static function sameEnum(a:IrEnum, b:IrEnum):Bool {
		if (a == b)
			return true;
		if (a.name != b.name || (a.isRecursive == true) != (b.isRecursive == true) || a.inlineStorage != b.inlineStorage
			|| a.cases.length != b.cases.length)
			return false;
		for (index in 0...a.cases.length) {
			var left = a.cases[index], right = b.cases[index];
			if (left.name != right.name || !sameTypes(left.params, right.params))
				return false;
		}
		return true;
	}

	/** Every part of an `IrNative`. */
	public static function sameNative(a:IrNative, b:IrNative):Bool {
		if (a == b)
			return true;
		if (a.name != b.name || a.library != b.library || a.symbol != b.symbol || !sameTypes(a.arguments, b.arguments)
			|| !IrTypeIdentity.same(a.result, b.result))
			return false;
		var left = a.generatedFunctionDependencies ?? [], right = b.generatedFunctionDependencies ?? [];
		return sameNames(left, right);
	}

	/** Every part of an `IrCNative`. */
	public static function sameCNative(a:IrCNative, b:IrCNative):Bool {
		if (a == b)
			return true;
		if (a.name != b.name || a.library != b.library || a.symbol != b.symbol || a.signature != b.signature
			|| a.pointerOwnership != b.pointerOwnership || a.pointerRelease != b.pointerRelease
			|| a.pointerLength != b.pointerLength || a.pointerNullable != b.pointerNullable
			|| (a.pointerSize ?? 0) != (b.pointerSize ?? 0) || !sameFixedLayout(a.fixedResult, b.fixedResult)
			|| !sameTypes(a.arguments, b.arguments) || !IrTypeIdentity.same(a.result, b.result)
			|| a.argumentModes.length != b.argumentModes.length)
			return false;
		for (index in 0...a.argumentModes.length)
			if (!sameArgumentMode(a.argumentModes[index], b.argumentModes[index]))
				return false;
		return true;
	}

	/** Every part of an `IrStaticField`. */
	public static function sameStaticField(a:IrStaticField, b:IrStaticField):Bool
		return a == b || a.name == b.name && IrTypeIdentity.same(a.type, b.type);

	public static function sameTypes(a:Array<IrType>, b:Array<IrType>):Bool {
		if (a.length != b.length)
			return false;
		for (index in 0...a.length)
			if (!IrTypeIdentity.same(a[index], b[index]))
				return false;
		return true;
	}

	static function sameNames(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length)
			return false;
		for (index in 0...a.length)
			if (a[index] != b[index])
				return false;
		return true;
	}

	static function sameFixedLayout(a:Null<IrCNativeFixedLayout>, b:Null<IrCNativeFixedLayout>):Bool
		return a == null ? b == null : b != null && a.size == b.size && a.alignment == b.alignment
			&& a.pointerFree == b.pointerFree;

	static function sameArgumentMode(a:IrCNativeArgumentMode, b:IrCNativeArgumentMode):Bool
		return switch [a, b] {
			case [Value, Value], [BytesSize, BytesSize], [Output, Output], [InputOutput, InputOutput]: true;
			case [BytesInput(left), BytesInput(right)], [BytesOutput(left), BytesOutput(right)],
				[BytesInputOutput(left), BytesInputOutput(right)]:
				left == right;
			case [FixedInput(size, alignment, free), FixedInput(otherSize, otherAlignment, otherFree)],
				[FixedValue(size, alignment, free), FixedValue(otherSize, otherAlignment, otherFree)],
				[FixedOutput(size, alignment, free), FixedOutput(otherSize, otherAlignment, otherFree)],
				[FixedInputOutput(size, alignment, free), FixedInputOutput(otherSize, otherAlignment, otherFree)]:
				size == otherSize && alignment == otherAlignment && free == otherFree;
			default: false;
		};

	static function sameNativeLayout(a:Null<IrObjectNativeLayout>, b:Null<IrObjectNativeLayout>):Bool
		return a == null ? b == null : b != null && a.target == b.target && a.size == b.size
			&& a.alignment == b.alignment;

	static function sameFieldLayout(a:Null<IrObjectFieldNativeLayout>, b:Null<IrObjectFieldNativeLayout>):Bool
		return a == null ? b == null : b != null && a.offset == b.offset && a.size == b.size
			&& a.alignment == b.alignment
			&& a.signed == b.signed && a.inlineRecord == b.inlineRecord;

	static function sameStorage(a:Null<IrScalarStorage>, b:Null<IrScalarStorage>):Bool
		return a == null ? b == null : b != null && a.size == b.size && a.signed == b.signed;
}
