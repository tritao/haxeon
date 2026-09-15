import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlType;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new HlTypeArena(128),
		type = arena.allocType(),
		functionType = arena.allocTypeFunction();
	type.ref.kind = 11;
	type.ref.data.ref.typeParam = type;
	var storedTypeParam = type.ref.data.ref.typeParam;
	functionType.ref.nargs = 2;
	type.ref.kind = 10;
	type.ref.data.ref.fun = functionType;
	var storedFunction = type.ref.data.ref.fun;
	var nativeKind = HlTypeBridge.native_type_kind(type),
		nativeSize = HlTypeBridge.native_type_size(type),
		nativeArity = HlTypeBridge.native_type_function_arity(type);
	var reused:RawPtr<HlType>;
	arena.reset();
	reused = arena.allocType();
	reused.ref.kind = 7;
	var correct = type.ref.kind == 7 && storedFunction == functionType && storedTypeParam == type && reused.ref.kind == 7 && nativeKind == 10
		&& nativeSize == 8 && nativeArity == 2;
	arena.dispose();
	arena.dispose();
	return correct ? 42 : 1;
}
