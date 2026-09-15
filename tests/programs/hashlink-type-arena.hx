import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlType;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new HlTypeArena(128),
		type = arena.allocType(),
		functionType = arena.allocTypeFunction();
	type.ref.kind = 11;
	type.ref.data.ref.typeParam = type;
	var storedTypeParam = type.ref.data.ref.typeParam;
	functionType.ref.nargs = 0;
	type.ref.data.ref.fun = functionType;
	var storedFunction = type.ref.data.ref.fun;
	var reused:RawPtr<HlType>;
	arena.reset();
	reused = arena.allocType();
	reused.ref.kind = 7;
	var correct = type.ref.kind == 7 && storedFunction == functionType && storedTypeParam == type && reused.ref.kind == 7;
	arena.dispose();
	arena.dispose();
	return correct ? 42 : 1;
}
