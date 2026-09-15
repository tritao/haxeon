package runtime.hashlink;

import runtime.memory.RawPtr;

/** Builds HashLink type graphs in stable storage without exposing allocation policy. */
class HlTypeBuilder {
	public final arena:HlTypeArena;

	public function new(arena:HlTypeArena)
		this.arena = arena;

	public function primitive(kind:HlTypeKind):RawPtr<HlType> {
		var type = allocateType(kind);
		return type;
	}

	public function typeParameter(parameter:RawPtr<HlType>):RawPtr<HlType> {
		var type = allocateType(HlTypeKind.Reference);
		type.ref.data.ref.typeParam = parameter;
		return type;
	}

	public function functionType(returnType:RawPtr<HlType>, nargs:Int):RawPtr<HlType> {
		var functionData = arena.allocTypeFunction();
		var arguments:RawPtr<RawPtr<HlType>>;
		if (nargs == 0)
			arguments = RawPtr.nullPtr();
		else {
			arguments = arena.allocTypePointerArray(nargs);
			for (index in 0...nargs)
				arguments.offset(index).store(returnType);
		}
		functionData.ref.args = arguments;
		functionData.ref.ret = returnType;
		functionData.ref.nargs = cast nargs;
		functionData.ref.parent = RawPtr.nullPtr();
		functionData.ref.closureType.ref.kind = cast HlTypeKind.VoidType;
		functionData.ref.closureType.ref.pointer = RawPtr.nullPtr();
		functionData.ref.closure.ref.args = arguments;
		functionData.ref.closure.ref.ret = returnType;
		functionData.ref.closure.ref.nargs = cast nargs;
		functionData.ref.closure.ref.parent = RawPtr.nullPtr();
		var type = allocateType(HlTypeKind.Function);
		type.ref.data.ref.fun = functionData;
		return type;
	}

	function allocateType(kind:HlTypeKind):RawPtr<HlType> {
		var type = arena.allocType();
		type.ref.kind = cast kind;
		type.ref.data.ref.typeParam = RawPtr.nullPtr();
		type.ref.vobjProto = RawPtr.nullPtr();
		type.ref.markBits = RawPtr.nullPtr();
		type.ref.gcOwner = RawPtr.nullPtr();
		return type;
	}
}
