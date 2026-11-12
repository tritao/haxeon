package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.codec.IrTypeCodec;

/** Per-element constructors for inline arrays and checked dynamic-array conversions. */
class IrValueArrayFactory {
	public final element:IrType;
	public final layout:IrValueArrayLayout;
	public final helpers:IrValueArraySlotHelpers;
	public final bridge:IrValueArrayBridge;
	final suffix:String;

	public function new(objects:IrObjectTable, element:IrType, pointerBits:Int, target:IrValueLaneTarget, slotNamespace:Int, ?enums:Array<IrEnum>) {
		this.element = element;
		layout = new IrValueArrayLayout(objects, element, pointerBits, target, enums);
		helpers = new IrValueArraySlotHelpers(slotNamespace, element, layout.lanes);
		bridge = new IrValueArrayBridge(element, layout.storage, objects, helpers);
		suffix = haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
	}

	public function allocateName():String return "$value-array:allocate:" + suffix;
	public function retypeName():String return "$value-array:retype:" + suffix;
	public function rangeNativeName(operation:String):String return "$value-array:native-" + operation + ":" + suffix;
	function allocNative():String return "$value-array:native-allocate:" + suffix;
	function setBridgeNative():String return "$value-array:native-bridge:" + suffix;
	function retypeNative():String return "$value-array:native-retype:" + suffix;

	/** Generate these before requesting the slot helpers, which collect the access primitives they use. */
	public function functions():Array<IrFunction> {
		var arrayType:IrType = Array(element), builder = new IrBuilder(), length = builder.argument("length", I32);
		var args = layoutArguments(builder), array = builder.call(allocNative(), [length].concat(args), arrayType);
		builder.call(setBridgeNative(), [array].concat(closures(builder)), Void);
		builder.returnValue(array);
		var allocate = new IrFunction(allocateName(), builder.arguments, arrayType, builder.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayAccess, allocateName())));
		var retype = new IrBuilder(), input = retype.argument("array", Array(Dyn));
		var retyped = retype.call(retypeNative(), [input].concat(layoutArguments(retype)).concat(closures(retype)), arrayType);
		retype.returnValue(retyped);
		return [allocate, new IrFunction(retypeName(), retype.arguments, arrayType, retype.blocks, Provider(TypeKey.of(element), ProviderOperations.detailed(ProviderOperation.ValueArrayAccess, retypeName())))].concat(bridge.functions());
	}

	public function natives():Array<IrNative> {
		var arrayType:IrType = Array(element), readType:IrType = Function([arrayType, I32], Dyn),
			writeType:IrType = Function([arrayType, I32, Dyn, Bool], Void), acceptsType:IrType = Function([Dyn], Bool),
			layoutTypes:Array<IrType> = [TypeRef, I32, I32, I32, Bool];
		return [
			{name: allocNative(), library: "haxeon_runtime", symbol: "__value_array_alloc", arguments: [I32].concat(layoutTypes), result: arrayType},
			{name: setBridgeNative(), library: "haxeon_runtime", symbol: "__value_array_set_bridge",
				arguments: [arrayType, readType, writeType, acceptsType], result: Void},
			{name: retypeNative(), library: "haxeon_runtime", symbol: "__value_array_retype",
				arguments: [Array(Dyn)].concat(layoutTypes).concat([readType, writeType, acceptsType]), result: arrayType},
			{name: "__value_array_ensure", library: "haxeon_runtime", symbol: "__value_array_ensure", arguments: [Array(Dyn), I32], result: Void},
			{name: "__value_array_prepare_write", library: "haxeon_runtime", symbol: "__value_array_prepare_write",
				arguments: [Array(Dyn), I32, Bool, Bool], result: I32},
			{name: "__value_array_mark", library: "haxeon_runtime", symbol: "__value_array_mark", arguments: [Array(Dyn), I32], result: Void},
			{name: "__value_array_remove_at", library: "haxeon_runtime", symbol: "__value_array_remove_at", arguments: [Array(Dyn), I32], result: Void},
			{name: "__value_array_insert_empty", library: "haxeon_runtime", symbol: "__value_array_insert_empty",
				arguments: [Array(Dyn), I32], result: I32},
			{name: "__value_array_resize", library: "haxeon_runtime", symbol: "__value_array_resize", arguments: [Array(Dyn), I32], result: Void},
			{name: "__value_array_reverse", library: "haxeon_runtime", symbol: "__value_array_reverse", arguments: [Array(Dyn)], result: Void},
			{name: IrValueArrayElements.spliceNativeName(element), library: "haxeon_runtime", symbol: "__value_array_splice",
				arguments: [Array(Dyn), I32, I32], result: arrayType},
			{name: rangeNativeName("copy"), library: "haxeon_runtime", symbol: "__value_array_copy",
				arguments: [Array(Dyn)], result: arrayType},
			{name: rangeNativeName("slice"), library: "haxeon_runtime", symbol: "__value_array_slice",
				arguments: [Array(Dyn), I32, I32], result: arrayType},
			{name: rangeNativeName("concat"), library: "haxeon_runtime", symbol: "__value_array_concat",
				arguments: [Array(Dyn), Array(Dyn)], result: arrayType},
			{name: "__std_is_exact_type", library: "haxeon_runtime", symbol: "__std_is_exact_type", arguments: [Dyn, TypeRef], result: Bool}
		];
	}

	function layoutArguments(builder:IrBuilder):Array<IrValue> {
		var base = switch element { case Nullable(inner): inner; case EnumTag(name): Enum(name); default: element; }, shape = layout.lanes;
		return [builder.typeValue(base), builder.constInt(shape.scalarStrideBits), builder.constInt(shape.references),
			builder.constInt(shape.scalarWordBits), builder.constBool(layout.hasValidity)];
	}

	function closures(builder:IrBuilder):Array<IrValue> {
		var arrayType:IrType = Array(element);
		return [builder.staticClosure(bridge.readName(), Function([arrayType, I32], Dyn)),
			builder.staticClosure(bridge.writeName(), Function([arrayType, I32, Dyn, Bool], Void)),
			builder.staticClosure(bridge.acceptsName(), Function([Dyn], Bool))];
	}
}
