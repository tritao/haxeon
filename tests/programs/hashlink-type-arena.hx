import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlType;
import runtime.hashlink.HlTypeKind;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new HlTypeArena(128),
		builder = new HlTypeBuilder(arena),
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
	arena.reset();
	var voidType = builder.primitive(HlTypeKind.VoidType),
		builtFunction = builder.functionType(voidType, 3),
		builtParameter = builder.typeParameter(voidType),
		builtData = builtFunction.ref.data.ref.fun;
	var builtCorrect = builtData.ref.ret == voidType
		&& builtData.ref.args.offset(0).load() == voidType
		&& builtData.ref.closure.ref.ret == voidType
		&& builtData.ref.closure.ref.args.offset(2).load() == voidType
		&& builtParameter.ref.data.ref.typeParam == voidType
		&& HlTypeBridge.native_type_kind(voidType) == 0
		&& HlTypeBridge.native_type_kind(builtFunction) == 10
		&& HlTypeBridge.native_type_kind(builtParameter) == 14
		&& HlTypeBridge.native_type_function_arity(builtFunction) == 3;
	arena.dispose();
	arena.dispose();
	return correct && builtCorrect ? 42 : 1;
}
