class WasmGcNativePointerHolder {
	public var pointer:Null<hl.Abstract<"native_pointer">>;

	public function new(pointer:Null<hl.Abstract<"native_pointer">>) {
		this.pointer = pointer;
	}
}

@:hlNative("haxeon_runtime", "nativePointerFromAddress")
extern function nativePointerFromAddress(address:Int):hl.Abstract<"native_pointer">;

function main():Int {
	var pointer = nativePointerFromAddress(42),
		reflected:Dynamic = pointer,
		recovered:Null<hl.Abstract<"native_pointer">> = cast reflected,
		nullPointer:Null<hl.Abstract<"native_pointer">> = null,
		nullDynamic:Dynamic = nullPointer,
		recoveredNull:Null<hl.Abstract<"native_pointer">> = cast nullDynamic;
	var holder = new WasmGcNativePointerHolder(recovered);
	return holder.pointer != null && recoveredNull == null ? 42 : 0;
}
