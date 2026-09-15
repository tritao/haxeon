package runtime.hashlink;

import runtime.memory.RawPtr;

/** Decision made before a metadata generation is published. */
enum HlMetadataDecision {
	/** The candidate preserves the published type prefix and may be patched in. */
	Compatible;
	/** The candidate needs a structural runtime reload before it can replace the prefix. */
	RequiresReload(reason:String);
}

/** Haxe-side compatibility policy for append-only HashLink metadata generations. */
class HlMetadataCompatibility {
	/**
		Compare a candidate with the currently published generation.

		The existing type prefix must have identical layout metadata. Only primitive,
		abstract, and function descriptors may be appended without a structural
		reload. Physical pointers and derived runtime allocations are deliberately
		ignored; the comparison follows module-local type indices instead.
	*/
	public static function check(previous:Null<HlMetadataGeneration>, candidate:HlMetadataGeneration):HlMetadataDecision {
		if (candidate == null)
			throw "HashLink metadata compatibility cannot inspect a null generation";
		if (previous == null)
			return Compatible;
		if (previous.functionCount() != candidate.functionCount())
			return RequiresReload("module function table changed");
		for (index in 0...previous.functionCount())
			if (!sameType(previous, candidate, previous.functionType(index), candidate.functionType(index)))
				return RequiresReload('function signature changed at slot $index');

		var previousCount = previous.typeCount(), candidateCount = candidate.typeCount();
		if (candidateCount < previousCount)
			return RequiresReload("type table shrank");
		for (index in 0...previousCount) {
			var previousType = previous.type(index), candidateType = candidate.type(index);
			if (!sameType(previous, candidate, previousType, candidateType)
				|| !sameTypeData(previous, candidate, previousType, candidateType))
				return RequiresReload('type prefix changed at index $index');
		}
		for (index in previousCount...candidateCount)
			if (!isAppendable(candidate.type(index)))
				return RequiresReload('type $index is not append-compatible');
		return Compatible;
	}

	static function sameType(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlType>,
		right:RawPtr<HlType>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();

		var leftIndex = previous.typeIndex(left), rightIndex = candidate.typeIndex(right);
		if (leftIndex != -1 || rightIndex != -1)
			return leftIndex == rightIndex;
		return left == right;
	}

	static function sameTypeHeader(left:RawPtr<HlType>, right:RawPtr<HlType>):Bool
		return left.ref.kind == right.ref.kind;

	static function sameTypeData(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlType>,
		right:RawPtr<HlType>):Bool {
		if (!sameTypeHeader(left, right))
			return false;

		var kind:HlTypeKind = cast left.ref.kind;
		switch kind {
			case Function | Method:
				return sameFunction(previous, candidate, left.ref.data.ref.fun, right.ref.data.ref.fun);
			case Object | Struct:
				return sameObject(previous, candidate, left.ref.data.ref.obj, right.ref.data.ref.obj);
			case Enum:
				return sameEnum(previous, candidate, left.ref.data.ref.enumType, right.ref.data.ref.enumType);
			case Virtual:
				return sameVirtual(previous, candidate, left.ref.data.ref.virtualType, right.ref.data.ref.virtualType);
			case Abstract:
				return sameName(left.ref.data.ref.absName, right.ref.data.ref.absName);
			case Reference | Nullable | Packed:
				return sameType(previous, candidate, left.ref.data.ref.typeParam, right.ref.data.ref.typeParam);
			default:
				return true;
		}
	}

	static function sameFunction(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlTypeFunction>,
		right:RawPtr<HlTypeFunction>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var nargs:Int = cast(left.ref.nargs, Int);
		if (left.ref.nargs != right.ref.nargs
			|| !sameType(previous, candidate, left.ref.ret, right.ref.ret)
			|| !sameType(previous, candidate, left.ref.parent, right.ref.parent))
			return false;
		if (!sameTypeArray(previous, candidate, left.ref.args, right.ref.args, nargs))
			return false;
		return true;
	}

	static function sameObject(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlTypeObject>,
		right:RawPtr<HlTypeObject>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var nfields:Int = cast(left.ref.nfields, Int), nproto:Int = cast(left.ref.nproto, Int), nbindings:Int = cast(left.ref.nbindings, Int);
		if (left.ref.nfields != right.ref.nfields || left.ref.nproto != right.ref.nproto || left.ref.nbindings != right.ref.nbindings
			|| !sameName(left.ref.name, right.ref.name)
			|| !sameType(previous, candidate, left.ref.superType, right.ref.superType)
			|| left.ref.globalValue.isNull() != right.ref.globalValue.isNull())
			return false;
		if (!sameFields(previous, candidate, left.ref.fields, right.ref.fields, nfields)
			|| !samePrototypes(left.ref.proto, right.ref.proto, nproto)
			|| !sameInts(left.ref.bindings, right.ref.bindings, nbindings * 2))
			return false;
		return true;
	}

	static function sameFields(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlObjectField>,
		right:RawPtr<HlObjectField>, count:Int):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var index = 0;
		while (index < count) {
			var leftField = left.offset(index), rightField = right.offset(index);
			if (!sameName(leftField.ref.name, rightField.ref.name)
				|| leftField.ref.hashedName != rightField.ref.hashedName
				|| !sameType(previous, candidate, leftField.ref.type, rightField.ref.type))
				return false;
			index++;
		}
		return true;
	}

	static function samePrototypes(left:RawPtr<HlObjectProto>, right:RawPtr<HlObjectProto>, count:Int):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var index = 0;
		while (index < count) {
			var leftProto = left.offset(index), rightProto = right.offset(index);
			if (!sameName(leftProto.ref.name, rightProto.ref.name)
				|| leftProto.ref.findex != rightProto.ref.findex
				|| leftProto.ref.pindex != rightProto.ref.pindex
				|| leftProto.ref.hashedName != rightProto.ref.hashedName)
				return false;
			index++;
		}
		return true;
	}

	static function sameEnum(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlTypeObject.HlTypeEnum>,
		right:RawPtr<HlTypeObject.HlTypeEnum>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		if (!sameName(left.ref.name, right.ref.name)
			|| left.ref.nconstructs != right.ref.nconstructs
			|| left.ref.globalValue.isNull() != right.ref.globalValue.isNull())
			return false;
		if (left.ref.constructs.isNull() || right.ref.constructs.isNull())
			return left.ref.constructs.isNull() && right.ref.constructs.isNull();
		var nconstructs:Int = cast(left.ref.nconstructs, Int), index = 0;
		while (index < nconstructs) {
			var leftConstruct = left.ref.constructs.offset(index), rightConstruct = right.ref.constructs.offset(index);
			if (!sameName(leftConstruct.ref.name, rightConstruct.ref.name)
				|| leftConstruct.ref.nparams != rightConstruct.ref.nparams
				|| leftConstruct.ref.size != rightConstruct.ref.size
				|| leftConstruct.ref.hasPtr != rightConstruct.ref.hasPtr
				|| !sameTypeArray(previous, candidate, leftConstruct.ref.params, rightConstruct.ref.params, cast(leftConstruct.ref.nparams, Int))
				|| !sameInts(leftConstruct.ref.offsets, rightConstruct.ref.offsets, cast(leftConstruct.ref.nparams, Int)))
				return false;
			index++;
		}
		return true;
	}

	static function sameVirtual(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<HlTypeObject.HlTypeVirtual>,
		right:RawPtr<HlTypeObject.HlTypeVirtual>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var nfields:Int = cast(left.ref.nfields, Int);
		if (left.ref.nfields != right.ref.nfields)
			return false;
		return sameFields(previous, candidate, left.ref.fields, right.ref.fields, nfields);
	}

	static function sameTypeArray(previous:HlMetadataGeneration, candidate:HlMetadataGeneration, left:RawPtr<RawPtr<HlType>>,
		right:RawPtr<RawPtr<HlType>>, count:Int):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var index = 0;
		while (index < count) {
			if (!sameType(previous, candidate, left.offset(index).load(), right.offset(index).load()))
				return false;
			index++;
		}
		return true;
	}

	static function sameInts(left:RawPtr<Int32>, right:RawPtr<Int32>, count:Int):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var index = 0;
		while (index < count) {
			if (left.offset(index).load() != right.offset(index).load())
				return false;
			index++;
		}
		return true;
	}

	static function sameName(left:RawPtr<UInt16>, right:RawPtr<UInt16>):Bool {
		if (left.isNull() || right.isNull())
			return left.isNull() && right.isNull();
		var index = 0;
		while (true) {
			var leftCode = left.offset(index).load(), rightCode = right.offset(index).load();
			if (leftCode != rightCode)
				return false;
			if (leftCode == 0)
				return true;
			index++;
		}
	}

	static function isAppendable(type:RawPtr<HlType>):Bool {
		var kind:HlTypeKind = cast type.ref.kind;
		return kind == HlTypeKind.VoidType || kind == HlTypeKind.UInt8Type || kind == HlTypeKind.UInt16Type
			|| kind == HlTypeKind.Int32Type || kind == HlTypeKind.Int64Type || kind == HlTypeKind.Float32Type
			|| kind == HlTypeKind.Float64Type || kind == HlTypeKind.BoolType || kind == HlTypeKind.BytesType
			|| kind == HlTypeKind.DynamicType || kind == HlTypeKind.Function || kind == HlTypeKind.Method
			|| kind == HlTypeKind.Abstract;
	}
}
