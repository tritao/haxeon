package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HashLinkTypeBindings.NativeHlType;

/** Native mechanism for publishing one already-bound object prototype. */
interface HlObjectPrototypeKernel {
	function publishObjectPrototype(type:RawPtr<NativeHlType>):Void;
}
