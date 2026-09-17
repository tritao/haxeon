package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlFunction;

/** Haxe-arena-owned patched function descriptors consumed by the native JIT. */
class HlRuntimePatchFunctions {
	public final pointer:RawPtr<NativeModuleHlFunction>;
	public final count:Int;

	@:allow(compiler.hl.HlNativeMetadataBuilder)
	function new(pointer:RawPtr<NativeModuleHlFunction>, count:Int) {
		if (count <= 0 || pointer.isNull())
			throw "HashLink patch function metadata requires a non-empty descriptor array";
		this.pointer = pointer;
		this.count = count;
	}
}
